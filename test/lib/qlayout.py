#!/usr/bin/env python3
"""Query one uitest dumpLayout JSON.

The device's `uitest dumpLayout` exposes type, text, bounds, clickable, enabled,
opacity and selected for every node, so an assertion can be made on the widget
tree instead of on pixels. This tool filters that tree and prints what a shell
script can act on.

usage: qlayout.py FILE [filters] [--out FIELD] [--nth N]

filters:  --type T  --text EXACT  --text-contains SUB  --clickable true|false
          --enabled true|false  --opacity NUM  --min-area N  --max-area N
          --top-lt N --top-gt N --left-gt N --left-lt N --bottom-gt N --right-lt N
output:   center (default) | bounds | text | opacity | selected | count | list
"""

import argparse
import json
import sys


def nodes(tree):
    attrs = tree.get("attributes", {})
    if attrs:
        yield attrs
    for child in tree.get("children", []):
        yield from nodes(child)


def bounds_rect(text):
    # "[87,858][786,993]"
    digits = text.replace("][", ",").replace("[", "").replace("]", "")
    left, top, right, bottom = (int(v) for v in digits.split(","))
    return left, top, right, bottom


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("file")
    parser.add_argument("--type", dest="type_", default=None)
    parser.add_argument("--text", default=None)
    parser.add_argument("--text-contains", default=None)
    parser.add_argument("--clickable", default=None)
    parser.add_argument("--enabled", default=None)
    parser.add_argument("--opacity", type=float, default=None)
    parser.add_argument("--min-area", type=int, default=None)
    parser.add_argument("--max-area", type=int, default=None)
    parser.add_argument("--top-lt", type=int, default=None)
    parser.add_argument("--top-gt", type=int, default=None)
    parser.add_argument("--left-gt", type=int, default=None)
    parser.add_argument("--left-lt", type=int, default=None)
    parser.add_argument("--bottom-gt", type=int, default=None)
    parser.add_argument("--right-lt", type=int, default=None)
    parser.add_argument("--out", default="center")
    parser.add_argument("--nth", type=int, default=0)
    args = parser.parse_args()

    with open(args.file, encoding="utf-8") as handle:
        tree = json.load(handle)

    found = []
    for attrs in nodes(tree):
        if args.type_ and attrs.get("type") != args.type_:
            continue
        if args.text is not None and attrs.get("text") != args.text:
            continue
        if args.text_contains and args.text_contains not in attrs.get("text", ""):
            continue
        if args.clickable is not None and attrs.get("clickable") != args.clickable:
            continue
        if args.enabled is not None and attrs.get("enabled") != args.enabled:
            continue
        if args.opacity is not None:
            try:
                if abs(float(attrs.get("opacity", "1")) - args.opacity) > 0.01:
                    continue
            except ValueError:
                continue
        rect = bounds_rect(attrs["bounds"])
        area = (rect[2] - rect[0]) * (rect[3] - rect[1])
        if args.min_area is not None and area < args.min_area:
            continue
        if args.max_area is not None and area > args.max_area:
            continue
        left, top, right, bottom = rect
        if args.top_lt is not None and top >= args.top_lt:
            continue
        if args.top_gt is not None and top <= args.top_gt:
            continue
        if args.left_gt is not None and left <= args.left_gt:
            continue
        if args.left_lt is not None and left >= args.left_lt:
            continue
        if args.bottom_gt is not None and bottom <= args.bottom_gt:
            continue
        if args.right_lt is not None and right >= args.right_lt:
            continue
        found.append((attrs, rect))

    if args.out == "count":
        print(len(found))
        return 0
    if args.out == "list":
        for attrs, rect in found:
            print("{}\t{}\topacity={}\tselected={}\tclickable={}\t{}".format(
                attrs.get("type", ""), attrs.get("text", ""), attrs.get("opacity", ""),
                attrs.get("selected", ""), attrs.get("clickable", ""), attrs.get("bounds", "")))
        return 0

    if args.nth >= len(found):
        print("no match ({} found)".format(len(found)), file=sys.stderr)
        return 1

    attrs, rect = found[args.nth]
    if args.out == "bounds":
        print(attrs.get("bounds", ""))
    elif args.out == "center":
        print((rect[0] + rect[2]) // 2, (rect[1] + rect[3]) // 2)
    else:
        print(attrs.get(args.out, ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
