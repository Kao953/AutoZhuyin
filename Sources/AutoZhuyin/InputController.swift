import Carbon
import Cocoa
import InputMethodKit
import AutoZhuyinCore

/// Resources shared by every client connection.
enum Shared {
    static var server: IMKServer!
    static var candidates: IMKCandidates!

    static let learnedKey = "LearnedPreferences"

    /// ~/Library/Application Support/AutoZhuyin (user phrases, picked-candidate history).
    static let supportDir: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("AutoZhuyin")

    static let classifier: Classifier = {
        let bundle = Bundle.main
        let start = Date()
        let lexicon = Lexicon()
        if let url = bundle.url(forResource: "lexicon", withExtension: "txt"),
           let data = try? Data(contentsOf: url) {
            lexicon.load(data: data)
        }
        // Optional user phrases: ~/Library/Application Support/AutoZhuyin/user-phrases.txt
        if let userFile = supportDir?.appendingPathComponent("user-phrases.txt"),
           let text = try? String(contentsOf: userFile, encoding: .utf8) {
            lexicon.load(text)
        }
        let english = EnglishModel(commonWordsURL: bundle.url(forResource: "english-common", withExtension: "txt"),
                                   dictionaryURL: bundle.url(forResource: "english-dict", withExtension: "txt"),
                                   bigramURL: bundle.url(forResource: "english-bigram", withExtension: "json"))
        let saved = UserDefaults.standard.dictionary(forKey: learnedKey) as? [String: Int] ?? [:]
        let learned = LearnedPreferences(weights: saved) { weights in
            UserDefaults.standard.set(weights, forKey: learnedKey)
        }
        let historyFile = supportDir?.appendingPathComponent("user-history.json")
        let history = UserHistory(data: historyFile.map(UserHistory.load(from:)) ?? [:]) { data in
            guard let url = historyFile, let json = try? JSONEncoder().encode(data) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.write(to: url, options: .atomic)
        }
        let trained = Features.loadWeights(from: bundle.url(forResource: "classifier-weights", withExtension: "json"))
        NSLog("AutoZhuyin: data loaded in %.0f ms", Date().timeIntervalSince(start) * 1000)
        // Only needed for untoned syllables; build it off the startup path.
        DispatchQueue.global(qos: .utility).async { lexicon.prepareTonelessIndex() }
        return Classifier(lexicon: lexicon, english: english, learned: learned, weights: trained, history: history)
    }()
}

@objc(AutoZhuyinInputController)
final class InputController: IMKInputController {
    private lazy var engine: CompositionEngine = {
        let e = CompositionEngine(classifier: Shared.classifier)
        e.reranker = AI.reranker
        return e
    }()
    private var shiftTap = ShiftTapDetector()

    // MARK: - Key events

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }

        // Shift pressed and released alone: next word is English (or flip the current one).
        if event.type == .flagsChanged {
            let flags = event.modifierFlags
            let tapped = shiftTap.modifiersChanged(
                shift: flags.contains(.shift),
                otherModifiers: !flags.intersection([.command, .control, .option, .function]).isEmpty,
                time: event.timestamp)
            if tapped {
                let idle = engine.keys.isEmpty
                _ = engine.handle(.shiftTap)
                updateComposition(client)
                // English mode on/off: switch input mode so the menu-bar icon shows it.
                if idle { InputModes.select(english: engine.isEnglishMode) }
            }
            return false
        }
        guard event.type == .keyDown else { return false }
        shiftTap.keyPressed()

        // Shortcuts (⌘C, ⌃A, ⌥…) go to the app; commit any composition first.
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            commit(engine.commitAll(), to: client)
            return false
        }

        // While the candidate panel is up, let it handle navigation keys itself.
        if engine.isShowingCandidates, [125, 126, 123, 124, 116, 121, 36, 76].contains(event.keyCode) {
            Shared.candidates.interpretKeyEvents([event])
            return true
        }

        guard let key = keyInput(for: event) else { return false }
        let result = engine.handle(key)
        if let text = result.commit { commit(text, to: client) }
        updateComposition(client)
        return result.handled
    }

    private func keyInput(for event: NSEvent) -> KeyInput? {
        switch event.keyCode {
        case 51: return .backspace
        case 36, 76: return .enter
        case 53: return .escape
        case 48: return .tab
        case 125: return .down
        case 126: return .up
        case 123: return .left
        case 124: return .right
        default:
            guard let c = event.characters?.first, !c.isNewline else { return nil }
            // Caps Lock without Shift: treat as lowercase so Zhuyin still works.
            if event.modifierFlags.contains(.capsLock) && !event.modifierFlags.contains(.shift) {
                return .character(Character(c.lowercased()))
            }
            return .character(c)
        }
    }

    // MARK: - Client updates

    private func commit(_ text: String, to client: IMKTextInput) {
        guard !text.isEmpty else { return }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func updateComposition(_ client: IMKTextInput) {
        // Each segment is underlined; literal (English) segments are blue as a hint.
        let marked = NSMutableAttributedString()
        for piece in engine.markedPieces {
            marked.append(NSAttributedString(string: piece.text, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: piece.mode == .literal ? NSColor.systemBlue : NSColor.textColor,
            ]))
        }
        let text = marked.string
        // Caret at the candidate cursor (UTF-16 offset of the first `cursorOffset` characters).
        let caret = String(text.prefix(engine.cursorOffset)).utf16.count
        client.setMarkedText(marked,
                             selectionRange: NSRange(location: caret, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))

        if engine.isShowingCandidates {
            Shared.candidates.update()
            Shared.candidates.show(kIMKLocateCandidatesBelowHint)
        } else {
            Shared.candidates.hide()
        }
    }

    /// The input mode changed (menu bar, keyboard shortcut, or our own Shift tap).
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        if tag == kTextServiceInputModePropertyTag, let id = value as? String {
            let english = InputModes.isEnglish(id)
            if english != engine.isEnglishMode {
                commitComposition(sender)
                engine.setEnglishMode(english)
            }
        }
        super.setValue(value, forTag: tag, client: sender)
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        commit(engine.commitAll(), to: client)
        Shared.candidates.hide()
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    // MARK: - Candidate panel

    override func candidates(_ sender: Any!) -> [Any]! {
        engine.candidates.map(\.text)
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        if let s = candidateString?.string, let i = engine.candidates.firstIndex(where: { $0.text == s }) {
            engine.candidateIndex = i
        }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let s = candidateString?.string,
              let i = engine.candidates.firstIndex(where: { $0.text == s }) else { return }
        engine.selectCandidate(i)
        if let client = client() { updateComposition(client) }
    }

    // MARK: - Menu

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        let modes: [(Reranker.Mode, String, Selector)] = [
            (.off, "AI 選字：關閉", #selector(aiOff(_:))),
            (.saver, "AI 選字：省電", #selector(aiSaver(_:))),
            (.standard, "AI 選字：標準", #selector(aiStandard(_:))),
            (.quality, "AI 選字：高品質", #selector(aiQuality(_:))),
        ]
        for (mode, title, action) in modes {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.state = AI.reranker.mode == mode ? .on : .off
        }
        let pause = menu.addItem(withTitle: "系統忙碌時自動暫停 AI", action: #selector(toggleAutoPause(_:)), keyEquivalent: "")
        pause.state = AI.autoPause ? .on : .off
        let status = menu.addItem(withTitle: AI.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "清除學習紀錄", action: #selector(clearLearned(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func aiOff(_ sender: Any?) { AI.setMode(.off) }
    @objc private func aiSaver(_ sender: Any?) { AI.setMode(.saver) }
    @objc private func aiStandard(_ sender: Any?) { AI.setMode(.standard) }
    @objc private func aiQuality(_ sender: Any?) { AI.setMode(.quality) }
    @objc private func toggleAutoPause(_ sender: Any?) { AI.autoPause.toggle() }

    @objc private func clearLearned(_ sender: Any?) {
        Shared.classifier.learned.clear()
        Shared.classifier.history.clear()
    }
}
