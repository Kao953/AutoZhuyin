import Cocoa
import InputMethodKit
import AutoZhuyinCore

/// Resources shared by every client connection.
enum Shared {
    static var server: IMKServer!
    static var candidates: IMKCandidates!

    static let learnedKey = "LearnedPreferences"

    static let classifier: Classifier = {
        let bundle = Bundle.main
        let lexicon = Lexicon()
        if let url = bundle.url(forResource: "lexicon", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            lexicon.load(text)
        }
        // Optional user phrases: ~/Library/Application Support/AutoZhuyin/user-phrases.txt
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let userFile = support.appendingPathComponent("AutoZhuyin/user-phrases.txt")
            if let text = try? String(contentsOf: userFile, encoding: .utf8) { lexicon.load(text) }
        }
        let english = EnglishModel(commonWordsURL: bundle.url(forResource: "english-common", withExtension: "txt"))
        let saved = UserDefaults.standard.dictionary(forKey: learnedKey) as? [String: Int] ?? [:]
        let learned = LearnedPreferences(weights: saved) { weights in
            UserDefaults.standard.set(weights, forKey: learnedKey)
        }
        let trained = Features.loadWeights(from: bundle.url(forResource: "classifier-weights", withExtension: "json"))
        return Classifier(lexicon: lexicon, english: english, learned: learned, weights: trained)
    }()
}

@objc(AutoZhuyinInputController)
final class InputController: IMKInputController {
    private let engine = CompositionEngine(classifier: Shared.classifier)
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
                _ = engine.handle(.shiftTap)
                updateComposition(client)
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
        menu.addItem(withTitle: "清除學習紀錄", action: #selector(clearLearned(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func clearLearned(_ sender: Any?) {
        Shared.classifier.learned.clear()
    }
}
