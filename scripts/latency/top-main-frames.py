"""Prints the main thread's top frames from an `xctrace export` of a time-profile table.

Usage: python3 -I scripts/latency/top-main-frames.py PROFILE.xml

Self time counts the sample's leaf frame; total time counts each distinct frame on the stack.
"""

import sys
import xml.etree.ElementTree as ET
from collections import Counter


def main(path):
    root = ET.parse(path).getroot()
    by_id = {}
    for element in root.iter():
        if "id" in element.attrib:
            by_id[element.attrib["id"]] = element

    def resolve(element):
        if element is not None and "ref" in element.attrib:
            return by_id.get(element.attrib["ref"])
        return element

    def frame_name(frame):
        name = frame.attrib.get("name", frame.attrib.get("addr", "?"))
        if name.startswith("<deduplicated"):
            binary = resolve(frame.find("binary"))
            return f"<{binary.attrib.get('name', '?') if binary is not None else '?'} symbol>"
        return name

    leaf = Counter()
    total = Counter()
    main_ms = 0.0
    for row in root.iter("row"):
        thread = resolve(row.find("thread"))
        if thread is None or "Main Thread" not in thread.attrib.get("fmt", ""):
            continue
        weight = resolve(row.find("weight"))
        ms = float(weight.text) / 1e6 if weight is not None and weight.text else 1.0
        backtrace = resolve(row.find("tagged-backtrace"))
        if backtrace is None:
            backtrace = resolve(row.find("backtrace"))
        if backtrace is None:
            continue
        names = []
        for frame in backtrace.findall("frame"):
            frame = resolve(frame)
            if frame is not None:
                names.append(frame_name(frame))
        if not names:
            continue
        main_ms += ms
        leaf[names[0]] += ms
        for name in set(names):
            total[name] += ms

    print(f"Main thread: {main_ms:.0f} ms sampled")
    print("Top 5 by self time:")
    for name, ms in leaf.most_common(5):
        print(f"  {ms:8.0f} ms  {100 * ms / max(main_ms, 1):5.1f}%  {name}")
    print("Top 45 by total time:")
    for name, ms in total.most_common(45):
        print(f"  {ms:8.0f} ms  {100 * ms / max(main_ms, 1):5.1f}%  {name}")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0 if len(sys.argv) == 2 else 64)
    main(sys.argv[1])
