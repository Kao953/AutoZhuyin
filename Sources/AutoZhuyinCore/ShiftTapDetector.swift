import Foundation

/// Detects Shift pressed and released on its own (no other key in between, released
/// within `maxDuration`), as opposed to Shift used for capitals or shortcuts.
///
/// Python twin: windows/autozhuyin/core/shift_tap.py
public struct ShiftTapDetector {
    public var maxDuration: TimeInterval = 0.5
    private var pressedAt: TimeInterval?
    private var used = false

    public init() {}

    /// Call when the modifier state changes. Returns true when a Shift tap completed.
    public mutating func modifiersChanged(shift: Bool, otherModifiers: Bool, time: TimeInterval) -> Bool {
        if shift && !otherModifiers {
            if pressedAt == nil {
                pressedAt = time
                used = false
            }
            return false
        }
        defer { pressedAt = nil }
        guard let start = pressedAt, !shift, !otherModifiers, !used else { return false }
        return time - start <= maxDuration
    }

    /// Call for every other key press: Shift was used as a modifier, not tapped.
    public mutating func keyPressed() {
        if pressedAt != nil { used = true }
    }
}
