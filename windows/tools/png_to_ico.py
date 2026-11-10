#!/usr/bin/env python3
"""Wraps a PNG into a single-image .ico file. Usage: png_to_ico.py in.png out.ico"""
import struct
import sys

png = open(sys.argv[1], "rb").read()
width, height = struct.unpack(">II", png[16:24])
header = struct.pack("<HHH", 0, 1, 1)                     # reserved, type=icon, count
entry = struct.pack("<BBBBHHII",
                    width % 256, height % 256, 0, 0,       # 0 means 256
                    1, 32, len(png), 6 + 16)               # planes, bpp, size, offset
open(sys.argv[2], "wb").write(header + entry + png)
