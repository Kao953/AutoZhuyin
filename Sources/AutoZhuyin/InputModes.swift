import Carbon
import Foundation

/// The two input modes declared in Info.plist (ComponentInputModeDict). Each has its own
/// menu-bar icon, so switching modes is how the icon shows "中英自動" vs "英文".
enum InputModes {
    static let auto = "com.autozhuyin.inputmethod.AutoZhuyin.Auto"
    static let english = "com.autozhuyin.inputmethod.AutoZhuyin.English"

    static func isEnglish(_ modeID: String) -> Bool { modeID == english }

    private static func source(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }

    /// Makes the given mode current (enabling it first if needed). Returns false on failure.
    @discardableResult
    static func select(english: Bool) -> Bool {
        guard let src = source(english ? InputModes.english : InputModes.auto) else { return false }
        TISEnableInputSource(src)
        return TISSelectInputSource(src) == noErr
    }

    /// Called by `--register`: enable both modes so they are in the input menu.
    static func enableAll() {
        for id in [auto, english] {
            if let src = source(id) { TISEnableInputSource(src) }
        }
    }
}
