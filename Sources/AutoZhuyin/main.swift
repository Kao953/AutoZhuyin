import Carbon
import Cocoa
import InputMethodKit

// `AutoZhuyin --register`: register this bundle with Text Input Sources so it shows up
// in System Settings without logging out (used by the installer's postinstall script).
if CommandLine.arguments.contains("--register") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    if status == noErr { InputModes.enableAll() }   // "中英自動" and "英文" (menu-bar icons)
    print(status == noErr ? "Registered \(Bundle.main.bundlePath)" : "TISRegisterInputSource failed: \(status)")
    exit(status == noErr ? 0 : 1)
}

// Entry point of the input method server. macOS launches this process when the
// input method is selected; IMKServer then creates one InputController per client.
guard let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
      let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
else {
    NSLog("AutoZhuyin: failed to start IMKServer (is this running from the .app bundle?)")
    exit(1)
}

Shared.server = server
Shared.candidates = IMKCandidates(server: server, panelType: kIMKSingleColumnScrollingCandidatePanel)
_ = Shared.classifier   // load the lexicon now rather than on the first keystroke
AI.loadModelIfNeeded()   // "AI 選字" language model, in the background

NSApplication.shared.run()
