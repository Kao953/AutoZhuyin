import CryptoKit
import Foundation
import AutoZhuyinCore

/// "AI 選字" settings, model loading and system-load detection for the Mac app.
enum AI {
    static let modeKey = "AIMode"
    static let autoPauseKey = "AIAutoPause"

    static let reranker: Reranker = {
        let saved = UserDefaults.standard.string(forKey: modeKey).flatMap(Reranker.Mode.init(rawValue:))
        let r = Reranker(mode: saved ?? .standard)
        r.systemState = { SystemMonitor.shared.state() }
        r.onUpdate = { InputController.refreshActive() }
        return r
    }()

    /// The model file is missing from the app bundle (built without scripts/fetch-lm.sh).
    private(set) static var modelMissing = false
    private static var loading = false

    static var autoPause: Bool {
        get { UserDefaults.standard.object(forKey: autoPauseKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoPauseKey); SystemMonitor.shared.invalidate() }
    }

    static func setMode(_ mode: Reranker.Mode) {
        reranker.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        if mode == .off {
            reranker.model = nil       // free the memory
        }
        if mode != .quality {
            reranker.largeModel = nil
        }
        loadModelIfNeeded()
    }

    /// Loads the model in the background (only when AI is on), and the large one for 高品質.
    static func loadModelIfNeeded() {
        LargeModel.loadIfNeeded()
        guard reranker.mode != .off, reranker.model == nil, !loading, !modelMissing else { return }
        guard let bin = Bundle.main.url(forResource: "lm", withExtension: "bin"),
              let vocab = Bundle.main.url(forResource: "lm-vocab", withExtension: "txt") else {
            modelMissing = true
            return
        }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let start = Date()
            let model = try? GPT2LanguageModel(modelURL: bin, vocabURL: vocab)
            NSLog("AutoZhuyin: language model %@ in %.0f ms", model == nil ? "failed" : "loaded",
                  Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                loading = false
                if model == nil { modelMissing = true }
                if reranker.mode != .off { reranker.model = model }
            }
        }
    }

    static var statusText: String {
        if modelMissing { return "AI 模型未安裝" }
        switch reranker.status {
        case .off: return "AI 選字已關閉"
        case .loading: return "AI 模型載入中…"
        case .active:
            if SystemMonitor.shared.state() == .reduced { return "AI 使用中（省電：低耗電模式）" }
            if reranker.mode == .quality && reranker.largeModel == nil {
                return LargeModel.isInstalled ? "AI 使用中（高品質模型載入中…）" : "AI 使用中（未下載高品質模型，同標準）"
            }
            return "AI 使用中"
        case .pausedBusy: return "AI 已暫停：系統忙碌或過熱"
        case .pausedSlow: return "AI 已暫停：運算太慢，一分鐘後再試"
        }
    }
}

/// The 高品質 model (gpt2-base, ~200 MB): downloaded on request, or by the installer when
/// its option is checked, to ~/Library/Application Support/AutoZhuyin/lm-large.bin. It
/// uses the bundled lm-vocab.txt (the two models share a vocabulary).
enum LargeModel {
    static let url = URL(string: "https://github.com/Kao953/AutoZhuyin/releases/download/lm-large-v1/lm-large.bin")!
    static let sha256 = "0e376619d2d382b573406ce58beda871162c60541cbe7bdf306142228d230809"
    static let sizeText = "約 200 MB"

    enum State: Equatable {
        case notInstalled, downloading(Double), installed, failed(String)
    }

    static var fileURL: URL? { Shared.supportDir?.appendingPathComponent("lm-large.bin") }
    static var isInstalled: Bool { fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    private static var task: URLSessionDownloadTask?
    private static var lastError: String?
    private static var loading = false

    static var state: State {
        if let task { return .downloading(task.progress.fractionCompleted) }
        if isInstalled { return .installed }
        if let lastError { return .failed(lastError) }
        return .notInstalled
    }

    /// Loads it in the background when 高品質 is on and the file is there.
    static func loadIfNeeded() {
        let r = AI.reranker
        guard r.mode == .quality, r.largeModel == nil, !loading, isInstalled, let bin = fileURL,
              let vocab = Bundle.main.url(forResource: "lm-vocab", withExtension: "txt") else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let model = try? GPT2LanguageModel(modelURL: bin, vocabURL: vocab)
            DispatchQueue.main.async {
                loading = false
                if model == nil { lastError = "高品質模型讀取失敗，請重新下載"; try? FileManager.default.removeItem(at: bin) }
                if r.mode == .quality { r.largeModel = model }
            }
        }
    }

    static func download() {
        guard task == nil, let dest = fileURL else { return }
        lastError = nil
        let t = URLSession.shared.downloadTask(with: url) { tmp, response, error in
            // Check the file here: `tmp` is deleted when this returns.
            var problem: String?
            if let error {
                problem = (error as NSError).code == NSURLErrorCancelled ? nil : "下載失敗：\(error.localizedDescription)"
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                problem = code == 404 ? "下載失敗：伺服器上找不到高品質模型" : "下載失敗（HTTP \(code)）"
            } else if let tmp, digest(of: tmp) == sha256 {
                do {
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                } catch {
                    problem = "無法儲存高品質模型：\(error.localizedDescription)"
                }
            } else {
                problem = "下載的高品質模型不完整，請再試一次"
            }
            DispatchQueue.main.async {
                task = nil
                lastError = problem
                loadIfNeeded()
            }
        }
        task = t
        t.resume()
    }

    static func cancel() {
        task?.cancel()
    }

    static func remove() {
        AI.reranker.largeModel = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        lastError = nil
    }

    /// SHA-256 of a file, read in pieces (it is large).
    private static func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Decides when AI should step back: paused when the Mac is hot or the CPU is busy,
/// reduced (fewest candidates) in Low Power Mode. Checked at most every 2 seconds.
final class SystemMonitor {
    static let shared = SystemMonitor()
    private var cached: (time: Date, state: Reranker.SystemState) = (.distantPast, .normal)
    /// CPU load (1-minute average per core) above which AI pauses.
    var busyLoad = 0.9

    func invalidate() { cached.time = .distantPast }

    func state() -> Reranker.SystemState {
        if Date().timeIntervalSince(cached.time) < 2 { return cached.state }
        cached = (Date(), compute())
        return cached.state
    }

    private func compute() -> Reranker.SystemState {
        guard AI.autoPause else { return .normal }
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical { return .paused }
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0, load[0] / Double(max(1, info.activeProcessorCount)) > busyLoad {
            return .paused
        }
        if info.isLowPowerModeEnabled { return .reduced }
        return .normal
    }
}
