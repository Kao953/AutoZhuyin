import Foundation

/// "AI 選字": reranks the converter's best paths with a language model.
///
///     score = lexicon score (log10 → ln) + λ · LM log-probability
///
/// It never blocks typing for long: each rerank has a time budget, and a rerank that runs
/// over it is dropped (the plain lexicon result is used). Three overruns in a row pause
/// AI for a minute. `systemState` lets the app pause or reduce it when the machine is
/// busy, hot or saving power.
public final class Reranker {
    public enum Mode: String, CaseIterable {
        case off, saver, standard, quality

        /// How many paths are reranked, and the time budget for one rerank.
        var k: Int { [.saver: 3, .standard: 10, .quality: 30][self] ?? 0 }
        var budget: TimeInterval { [.saver: 0.015, .standard: 0.04, .quality: 0.12][self] ?? 0 }
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
    public var systemState: () -> SystemState = { .normal }
    public var now: () -> Date = Date.init
    public private(set) var status: Status = .off

    private var overruns = 0
    private var pausedUntil = Date.distantPast
    private var cache: [String: [ConvertedSegment]] = [:]
    static let cacheLimit = 512
    static let pauseAfterOverruns = 3
    static let slowPause: TimeInterval = 60

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
    }

    /// The reranked conversion, or nil to use the plain lexicon result.
    func choose(_ converter: Converter, _ syllables: [Syllable], fixed: [Range<Int>: String],
                context: String) -> [ConvertedSegment]? {
        guard let mode = effectiveMode, let model, !syllables.isEmpty else { return nil }
        let key = "\(mode.rawValue)|\(context)|\(syllables.map(\.reading).joined(separator: "-"))|"
            + fixed.sorted { $0.key.lowerBound < $1.key.lowerBound }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
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
}
