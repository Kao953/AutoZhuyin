import Cocoa
import InputMethodKit

/// A small "中" / "A" badge shown under the text cursor for a moment when English mode is
/// switched on or off (the menu-bar icon of an input method can't change on its own).
enum ModeIndicator {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var hideWork: DispatchWorkItem?

    static func show(english: Bool, client: IMKTextInput) {
        let (panel, label) = makePanel()
        label.stringValue = english ? "A" : "中"

        var lineRect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
        let size = panel.frame.size
        var origin = NSPoint(x: lineRect.minX, y: lineRect.minY - size.height - 4)
        if lineRect == .zero, let screen = NSScreen.main {   // the app gave no caret position
            origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private static func makePanel() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let side: CGFloat = 28
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let background = NSVisualEffectView(frame: p.contentView!.bounds)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]

        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.alignment = .center
        l.frame = NSRect(x: 0, y: (side - 20) / 2, width: side, height: 20)
        background.addSubview(l)
        p.contentView = background
        panel = p
        label = l
        return (p, l)
    }
}
