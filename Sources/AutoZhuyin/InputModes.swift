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

    private static func isEnabled(_ src: TISInputSource) -> Bool {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }

    /// Makes the given mode current. Returns false on failure.
    /// Only enables the mode if it is not enabled yet: TISEnableInputSource opens System
    /// Settings → Keyboard, even for a source that is already enabled.
    @discardableResult
    static func select(english: Bool) -> Bool {
        guard let src = source(english ? InputModes.english : InputModes.auto) else { return false }
        if !isEnabled(src) { TISEnableInputSource(src) }
        return TISSelectInputSource(src) == noErr
    }

    /// Called by `--register`: enable both modes (if not yet) so they are in the input menu.
    static func enableAll() {
        for id in [auto, english] {
            if let src = source(id), !isEnabled(src) { TISEnableInputSource(src) }
        }
    }
}
