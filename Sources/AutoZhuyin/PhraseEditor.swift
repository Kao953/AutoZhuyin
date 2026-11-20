import Cocoa
import AutoZhuyinCore

/// The user phrase editor ("編輯自訂詞…" in the input menu). It runs as its own process
/// (`AutoZhuyin --edit-phrases`), a regular app with a window, so that text can be typed
/// into it with any input method, AutoZhuyin included: the input method server itself
/// can't be its own client.
///
/// Every change is written to user-phrases.txt at once; the input method reloads the file
/// when it gets `PhraseEditor.changedNotification` (and when the file's date changes).
enum PhraseEditor {
    static let changedNotification = Notification.Name("com.autozhuyin.inputmethod.userPhrasesChanged")
    static let showNotification = Notification.Name("com.autozhuyin.inputmethod.showPhraseEditor")

    static var fileURL: URL? { Shared.supportDir?.appendingPathComponent("user-phrases.txt") }

    private static var process: Process?

    /// Called by the input method: opens the editor, or brings it forward.
    static func open() {
        if let process, process.isRunning {
            DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            return
        }
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--edit-phrases"]
        do {
            try p.run()
            process = p
        } catch {
            NSLog("AutoZhuyin: can't start the phrase editor: \(error)")
        }
    }

    /// Entry point of `AutoZhuyin --edit-phrases`.
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = PhraseEditorController()
        app.delegate = controller
        app.mainMenu = makeMainMenu()
        controller.showWindow()
        app.activate(ignoringOtherApps: true)
        app.run()
        exit(0)
    }

    /// Without an Edit menu, ⌘C / ⌘V / ⌘Z don't work in the text fields.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = main.addItem(withTitle: "編輯", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "編輯")
        edit.addItem(withTitle: "還原", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = main.addItem(withTitle: "視窗", action: nil, keyEquivalent: "")
        let window = NSMenu(title: "視窗")
        window.addItem(withTitle: "關閉", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        return main
    }
}

final class PhraseEditorController: NSObject, NSApplicationDelegate, NSWindowDelegate,
                                    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var phrases = UserPhrases()
    /// Built-in lexicon plus user phrases, for filling in readings.
    private let lexicon = Lexicon()

    private var window: NSWindow!
    private let phraseField = NSTextField()
    private let readingField = NSTextField()
    private let addButton = NSButton(title: "加入", target: nil, action: nil)
    private let removeButton = NSButton(title: "刪除", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")
    private let table = NSTableView()
    /// The reading field holds what was filled in from the lexicon, not something typed.
    private var readingIsSuggested = false

    override init() {
        super.init()
        if let url = Bundle.main.url(forResource: "lexicon", withExtension: "txt"),
           let data = try? Data(contentsOf: url) {
            lexicon.load(data: data)
        }
        if let url = PhraseEditor.fileURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            phrases = UserPhrases(text: text)
        }
        lexicon.setUserPhrases(phrases.text)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(bringForward), name: PhraseEditor.showNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window

    func showWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "自動注音：自訂詞"
        window.minSize = NSSize(width: 440, height: 300)
        window.delegate = self
        window.isReleasedWhenClosed = false

        phraseField.placeholderString = "詞，例如：自動注音"
        readingField.placeholderString = "注音：ㄗˋ ㄉㄨㄥˋ… 或大千鍵位 y42j/4…"
        for field in [phraseField, readingField] {
            field.delegate = self
            field.target = self
            field.action = #selector(add(_:))
        }
        addButton.target = self
        addButton.action = #selector(add(_:))
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false
        let reveal = NSButton(title: "在 Finder 中顯示檔案", target: self, action: #selector(revealFile(_:)))
        reveal.bezelStyle = .rounded

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        showHint()

        for (id, title, width) in [("phrase", "詞", 180.0), ("reading", "注音", 280.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.style = .inset
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let inputRow = NSStackView(views: [phraseField, readingField, addButton])
        inputRow.spacing = 8
        phraseField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let bottomRow = NSStackView(views: [removeButton, NSView(), reveal])
        let stack = NSStackView(views: [inputRow, message, scroll, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for row in [inputRow, scroll, bottomRow] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(phraseField)
    }

    private func showHint() {
        message.textColor = .secondaryLabelColor
        message.stringValue = "打好詞會自動填入常用讀音，可以再修改。選字時自訂詞會排在最前面。"
    }

    private func showProblem(_ text: String) {
        message.textColor = .systemRed
        message.stringValue = text
        NSSound.beep()
    }

    // MARK: - Editing

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        if field === phraseField {
            if readingField.stringValue.isEmpty || readingIsSuggested {
                let phrase = phraseField.stringValue.trimmingCharacters(in: .whitespaces)
                readingField.stringValue = lexicon.reading(of: phrase).map(spaced) ?? ""
                readingIsSuggested = true
            }
        } else if field === readingField {
            readingIsSuggested = false
        }
    }

    /// "ㄗˋ-ㄉㄨㄥˋ" → "ㄗˋ ㄉㄨㄥˋ", easier to read and edit.
    private func spaced(_ reading: String) -> String {
        reading.replacingOccurrences(of: "-", with: " ")
    }

    /// The entry typed in the two fields, or nil after showing what's wrong.
    private func entry(phrase rawPhrase: String, reading typed: String, score: Double?) -> UserPhrases.Entry? {
        let phrase = rawPhrase.trimmingCharacters(in: .whitespaces)
        guard let reading = UserPhrases.reading(fromTyped: typed) ?? (typed.isEmpty ? "" : nil) else {
            showProblem("看不懂這個注音：\(typed)")
            return nil
        }
        if let problem = UserPhrases.problem(phrase: phrase, reading: reading) {
            showProblem(problem)
            return nil
        }
        return UserPhrases.Entry(phrase: phrase, reading: reading, score: score)
    }

    @objc private func add(_ sender: Any?) {
        guard let new = entry(phrase: phraseField.stringValue, reading: readingField.stringValue,
                              score: UserPhrases.defaultScore) else { return }
        if let i = phrases.entries.firstIndex(where: { $0.phrase == new.phrase && $0.reading == new.reading }) {
            showProblem("已經有「\(new.phrase)」了")
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
            return
        }
        phrases.append(new)
        save()
        let row = phrases.entries.count - 1
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        phraseField.stringValue = ""
        readingField.stringValue = ""
        readingIsSuggested = false
        message.textColor = .secondaryLabelColor
        message.stringValue = "已加入「\(new.phrase)」"
        window.makeFirstResponder(phraseField)
    }

    @objc private func removeSelected(_ sender: Any?) {
        for row in table.selectedRowIndexes.reversed() { phrases.remove(at: row) }
        table.deselectAll(nil)
        save()
    }

    @objc private func revealFile(_ sender: Any?) {
        guard let url = PhraseEditor.fileURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) { save() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func save() {
        table.reloadData()
        lexicon.setUserPhrases(phrases.text)
        guard let url = PhraseEditor.fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try phrases.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showProblem("無法儲存：\(error.localizedDescription)")
            return
        }
        DistributedNotificationCenter.default().postNotificationName(PhraseEditor.changedNotification, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { phrases.entries.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        let e = phrases.entries[row]
        let field = NSTextField(string: column.identifier.rawValue == "phrase" ? e.phrase : spaced(e.reading))
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.identifier = column.identifier
        field.target = self
        field.action = #selector(editCell(_:))
        return field
    }

    /// Editing a cell in place: keep the change if it is valid, otherwise put it back.
    @objc private func editCell(_ sender: NSTextField) {
        let row = table.row(for: sender)
        guard row >= 0, row < phrases.entries.count else { return }
        let old = phrases.entries[row]
        let isPhrase = sender.identifier?.rawValue == "phrase"
        let new = entry(phrase: isPhrase ? sender.stringValue : old.phrase,
                        reading: isPhrase ? old.reading : sender.stringValue, score: old.score)
        if let new {
            if new != old {
                phrases.replace(at: row, with: new)
                save()
            }
            showHint()
        } else {
            sender.stringValue = isPhrase ? old.phrase : spaced(old.reading)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
}
