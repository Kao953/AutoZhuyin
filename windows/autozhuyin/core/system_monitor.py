"""Decides when "AI 選字" should step back (Windows and Linux; the Mac app has its own).

paused  — CPU busy (over 90%), or the machine is very hot (Linux thermal zones ≥ 95 °C)
reduced — power saving (Windows battery saver; Linux low-power profile or battery ≤ 20%)
normal  — otherwise. Checked at most every 2 seconds.
"""
import glob
import os
import sys
import time

from .reranker import NORMAL, PAUSED, REDUCED


class SystemMonitor:
    interval = 2.0
    busy_load = 0.9

    def __init__(self, now=time.monotonic):
        self.now = now
        self._cached = (float("-inf"), NORMAL)
        self._cpu_prev = None

    def state(self):
        t, s = self._cached
        if self.now() - t < self.interval:
            return s
        try:
            s = self._compute()
        except Exception:
            s = NORMAL
        self._cached = (self.now(), s)
        return s

    def _compute(self):
        if sys.platform == "win32":
            return self._windows()
        return self._linux()

    # --- Linux ---

    def _linux(self):
        if os.getloadavg()[0] / max(1, os.cpu_count() or 1) > self.busy_load:
            return PAUSED
        temps = []
        for path in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
            try:
                temps.append(int(open(path).read().strip()) / 1000)
            except (OSError, ValueError):
                pass
        if temps and max(temps) >= 95:
            return PAUSED
        try:
            if open("/sys/firmware/acpi/platform_profile").read().strip() in ("low-power", "quiet"):
                return REDUCED
        except OSError:
            pass
        for bat in glob.glob("/sys/class/power_supply/BAT*"):
            try:
                status = open(bat + "/status").read().strip()
                capacity = int(open(bat + "/capacity").read().strip())
            except (OSError, ValueError):
                continue
            if status == "Discharging" and capacity <= 20:
                return REDUCED
        return NORMAL

    # --- Windows ---

    def _windows(self):
        import ctypes
        from ctypes import wintypes

        class FILETIME(ctypes.Structure):
            _fields_ = [("lo", wintypes.DWORD), ("hi", wintypes.DWORD)]

        idle, kernel, user = FILETIME(), FILETIME(), FILETIME()
        ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user))
        values = [(f.hi << 32) | f.lo for f in (idle, kernel, user)]
        prev, self._cpu_prev = self._cpu_prev, values
        if prev:
            d_idle, d_kernel, d_user = (a - b for a, b in zip(values, prev))
            total = d_kernel + d_user          # kernel time includes idle time
            if total > 0 and 1 - d_idle / total > self.busy_load:
                return PAUSED

        class SYSTEM_POWER_STATUS(ctypes.Structure):
            _fields_ = [("ACLineStatus", ctypes.c_ubyte), ("BatteryFlag", ctypes.c_ubyte),
                        ("BatteryLifePercent", ctypes.c_ubyte), ("SystemStatusFlag", ctypes.c_ubyte),
                        ("BatteryLifeTime", wintypes.DWORD), ("BatteryFullLifeTime", wintypes.DWORD)]

        status = SYSTEM_POWER_STATUS()
        if ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(status)) and status.SystemStatusFlag == 1:
            return REDUCED   # battery saver on
        return NORMAL
