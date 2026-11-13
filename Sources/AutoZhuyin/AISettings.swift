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
        } else {
            loadModelIfNeeded()
        }
    }

    /// Loads the model in the background (only when AI is on).
    static func loadModelIfNeeded() {
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
            return SystemMonitor.shared.state() == .reduced ? "AI 使用中（省電：低耗電模式）" : "AI 使用中"
        case .pausedBusy: return "AI 已暫停：系統忙碌或過熱"
        case .pausedSlow: return "AI 已暫停：運算太慢，一分鐘後再試"
        }
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
