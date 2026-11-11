"""Detects Shift pressed and released on its own. Port of ShiftTapDetector.swift."""


class ShiftTapDetector:
    max_duration = 0.5

    def __init__(self):
        self._pressed_at = None
        self._used = False

    def shift_down(self, time):
        if self._pressed_at is None:     # ignore auto-repeat
            self._pressed_at = time
            self._used = False

    def key_pressed(self):
        """Any other key while Shift is held: Shift was used as a modifier."""
        if self._pressed_at is not None:
            self._used = True

    def shift_up(self, time):
        """Returns True when this release completes a Shift tap."""
        start, self._pressed_at = self._pressed_at, None
        return start is not None and not self._used and time - start <= self.max_duration
