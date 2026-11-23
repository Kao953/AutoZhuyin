package com.autozhuyin.core

/** Detects Shift pressed and released on its own. Port of shift_tap.py. Times in milliseconds. */
class ShiftTapDetector(private val maxDurationMs: Long = 500) {
    private var pressedAt: Long? = null
    private var used = false

    fun shiftDown(timeMs: Long) {
        if (pressedAt == null) {   // ignore auto-repeat
            pressedAt = timeMs
            used = false
        }
    }

    /** Any other key while Shift is held: Shift was used as a modifier. */
    fun keyPressed() {
        if (pressedAt != null) used = true
    }

    /** True when this release completes a Shift tap. */
    fun shiftUp(timeMs: Long): Boolean {
        val start = pressedAt
        pressedAt = null
        return start != null && !used && timeMs - start <= maxDurationMs
    }
}
