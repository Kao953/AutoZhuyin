import Foundation

/// "AI 選字": reranks the converter's best paths with a language model.
///
///     score = lexicon score (log10 → ln) + λ · LM log-probability
///
/// It never blocks typing for long: each rerank has a time budget, and a rerank that runs
/// over it is dropped (the plain lexicon result is used). Three overruns in a row pause
/// AI for a minute. `systemState` lets the app pause or reduce it when the machine is
/// busy, hot or saving power.
///
/// 高品質 uses `largeModel` (gpt2-base, an optional download) when it is there. It is too
/// slow to run on each key, so it runs in the background: until its result is ready the
/// small model's is shown, `onUpdate` announces the result, and a commit waits for it a
/// little (see `choose`). Without the large model 高品質 is the same as 標準.
public final class Reranker {
    public enum Mode: String, CaseIterable {
        case off, saver, standard, quality

        /// How many paths the small model reranks, and the time budget for one rerank
        /// (more paths than 標準 gave no better results with the small model).
        var k: Int { [.saver: 3, .standard: 10, .quality: 10][self] ?? 0 }
        var budget: TimeInterval { [.saver: 0.015, .standard: 0.04, .quality: 0.04][self] ?? 0 }
    }

    /// What the system allows right now (decided by the app).
    public enum SystemState { case normal, reduced, paused }

    public enum Status: Equatable {
        case off, loading, active, pausedBusy, pausedSlow
    }

    public var mode: Mode { didSet { cache.removeAll() } }
    /// nil while loading (or if the model file is missing).
    public var model: LanguageModel? { didSet { cache.removeAll() } }
    public var lambda = 0.6
    /// The 高品質 model, reranking in the background; nil when not downloaded.
    public var largeModel: LanguageModel? { didSet { clearCache() } }
    /// Called on the main queue when a background rerank finished (redraw the composition).
    public var onUpdate: (() -> Void)?
    /// Paths and weight for the large model (windows/tools/eval_ai.py: best on both sets).
    static let largeK = 10, largeLambda = 2.0
    public var systemState: () -> SystemState = { .normal }
    public var now: () -> Date = Date.init
    public private(set) var status: Status = .off

    private var overruns = 0
    private var pausedUntil = Date.distantPast
    private var cache: [String: [ConvertedSegment]] = [:]
    static let cacheLimit = 512
    static let pauseAfterOverruns = 3
    static let slowPause: TimeInterval = 60

    private struct Job {
        let key: String, paths: [(score: Double, segments: [ConvertedSegment])], context: String
        let model: LanguageModel, generation: Int
    }
    /// Guards the large-model state below, shared with the background queue.
    private let condition = NSCondition()
    private var largeCache: [String: [ConvertedSegment]] = [:]
    private var queued: Job?
    private var runningKey: String?
    private var working = false
    private var generation = 0
    private let queue = DispatchQueue(label: "AutoZhuyin.rerank", qos: .userInitiated)

    public init(mode: Mode = .standard, model: LanguageModel? = nil) {
        self.mode = mode
        self.model = model
    }

    /// The mode actually used now (after the system state), or nil when AI is not used.
    var effectiveMode: Mode? {
        guard mode != .off else { status = .off; return nil }
        guard model != nil else { status = .loading; return nil }
        if now() < pausedUntil { status = .pausedSlow; return nil }
        switch systemState() {
        case .paused: status = .pausedBusy; return nil
        case .reduced: status = .active; return .saver
        case .normal: status = .active; return mode
        }
    }

    /// Forgets cached results (the lexicon changed).
    public func clearCache() {
        cache.removeAll()
        condition.lock()
        largeCache.removeAll()
        queued = nil
        generation += 1   // results still running are dropped
        condition.unlock()
    }

    /// The reranked conversion, or nil to use the plain lexicon result. `wait`: how long to
    /// wait for the large model's result (when committing); 0 shows the small model's
    /// result meanwhile.
    func choose(_ converter: Converter, _ syllables: [Syllable], fixed: [Range<Int>: String],
                context: String, wait: TimeInterval = 0) -> [ConvertedSegment]? {
        guard let mode = effectiveMode, let model, !syllables.isEmpty else { return nil }
        let key = "\(mode.rawValue)|\(context)|\(syllables.map(\.reading).joined(separator: "-"))|"
            + fixed.sorted { $0.key.lowerBound < $1.key.lowerBound }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        if mode == .quality, let large = largeModel,
           let chosen = chooseLarge(converter, syllables, fixed: fixed, context: context, key: key, model: large, wait: wait) {
            return chosen
        }
        if let hit = cache[key] { return hit }

        let paths = converter.kBest(syllables, fixed: fixed, k: mode.k)
        guard paths.count > 1 else { return paths.first?.segments }
        let start = now()
        var best: (score: Double, segments: [ConvertedSegment])?
        for path in paths {
            let text = path.segments.map(\.text).joined()
            let score = path.score * log(10) + lambda * model.logProb(text, context: context)
            if best == nil || score > best!.score { best = (score, path.segments) }
            if now().timeIntervalSince(start) > mode.budget {
                overruns += 1
                if overruns >= Reranker.pauseAfterOverruns {
                    pausedUntil = now().addingTimeInterval(Reranker.slowPause)
                    overruns = 0
                    status = .pausedSlow
                }
                return nil
            }
        }
        overruns = 0
        if cache.count >= Reranker.cacheLimit { cache.removeAll() }
        cache[key] = best?.segments
        return best?.segments
    }

    // MARK: - Large model, in the background

    private func chooseLarge(_ converter: Converter, _ syllables: [Syllable], fixed: [Range<Int>: String],
                             context: String, key: String, model: LanguageModel,
                             wait: TimeInterval) -> [ConvertedSegment]? {
        condition.lock()
        defer { condition.unlock() }
        if let hit = largeCache[key] { return hit }
        if runningKey != key && queued?.key != key {
            // k-best on this thread: the lexicon may change on it, never in the background.
            let paths = converter.kBest(syllables, fixed: fixed, k: Reranker.largeK)
            guard paths.count > 1 else { return paths.first?.segments }
            queued = Job(key: key, paths: paths, context: context, model: model, generation: generation)
            if !working {
                working = true
                queue.async { self.work() }
            }
        }
        let deadline = Date().addingTimeInterval(wait)
        while wait > 0, largeCache[key] == nil, runningKey == key || queued?.key == key {
            if !condition.wait(until: deadline) { break }
        }
        return largeCache[key]
    }

    /// Runs queued jobs one at a time; a newer job replaces one not started yet.
    private func work() {
        while true {
            condition.lock()
            guard let job = queued else {
                working = false
                condition.unlock()
                return
            }
            queued = nil
            runningKey = job.key
            condition.unlock()

            let scores = job.paths.map { path in
                path.score * log(10) + Reranker.largeLambda
                    * job.model.logProb(path.segments.map(\.text).joined(), context: job.context)
            }
            let best = scores.indices.max { scores[$0] < scores[$1] }.map { job.paths[$0] }

            condition.lock()
            runningKey = nil
            let current = job.generation == generation
            if current, let best {
                if largeCache.count >= Reranker.cacheLimit { largeCache.removeAll() }
                largeCache[job.key] = best.segments
            }
            condition.broadcast()
            condition.unlock()
            if current { DispatchQueue.main.async { self.onUpdate?() } }
        }
    }
}
