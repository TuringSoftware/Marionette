#!/usr/bin/env python3
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Reads one connection of a `marionettectl proxy` capture and prints the encodings the viewer asked
# for and how many pointer-position rectangles (encoding 0x44c) the Mac sent in each second.
#
#   pointer-rate.py <capture dir>/<NN>
import re
import struct
import sys

if len(sys.argv) != 2:
    sys.exit("usage: pointer-rate.py <capture dir>/<NN>")
directory = sys.argv[1]
viewer_to_mac = open(directory + "/viewer-to-mac.bin", "rb").read()
mac_to_viewer = open(directory + "/mac-to-viewer.bin", "rb").read()

for match in re.finditer(rb"\x02\x00(..)", viewer_to_mac, re.S):
    count = struct.unpack(">H", match.group(1))[0]
    end = match.start() + 4 + 4 * count
    if 3 <= count <= 40 and end <= len(viewer_to_mac):
        encodings = struct.unpack(">%di" % count, viewer_to_mac[match.start() + 4:end])
        if any(encoding in (0x3F2, 0x3F3, 6, 16) for encoding in encodings):
            names = [hex(e) if e > 255 or e < 0 else e for e in encodings]
            print("SetEncodings at byte %d: %s" % (match.start(), names))

# log.txt says when each chunk from the Mac arrived; that dates a byte offset.
arrivals = []
offset = 0
for line in open(directory + "/log.txt", encoding="utf-8", errors="replace"):
    match = re.match(r"\s*([0-9.]+) Mac→viewer \w+ @\d+ (\d+) bytes", line)
    if match:
        arrivals.append((offset, float(match.group(1))))
        offset += int(match.group(2))


def arrival(position):
    time = -1.0
    for start, at in arrivals:
        if start > position:
            break
        time = at
    return time


positions = [
    (match.start(), struct.unpack(">HH", match.group(1) + match.group(2)))
    for match in re.finditer(rb"(..)(..)\x00\x00\x00\x00\x00\x00\x04\x4c", mac_to_viewer, re.S)
]
print("Mac→viewer: %d bytes in %d chunks; 0x44c rectangles: %d" % (len(mac_to_viewer), len(arrivals), len(positions)))
per_second = {}
for position, _ in positions:
    second = int(arrival(position))
    per_second[second] = per_second.get(second, 0) + 1
print("per second:", " ".join("%d:%d" % item for item in sorted(per_second.items())))
for position, (x, y) in positions if len(positions) <= 6 else positions[:3] + positions[-3:]:
    print("  at %.2f s: %d, %d" % (arrival(position), x, y))
