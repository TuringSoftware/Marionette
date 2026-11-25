#!/usr/bin/env python3
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Brings each target's Localizable.xcstrings in line with the strings the compiler extracted from
# its source, as Xcode does when it builds in the app: new strings are added, and strings no longer
# in the source are removed unless they carry translations (those are listed instead).
#
#   xcodebuild build -project Marionette.xcodeproj -scheme Marionette \
#       -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData
#   Scripts/sync-string-catalogs.py [derived data folder]
import collections
import glob
import json
import os
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
derived = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "DerivedData")
extractions = glob.glob(os.path.join(derived, "Build/Intermediates.noindex/**/*.stringsdata"), recursive=True)
if not extractions:
    sys.exit("No extracted strings under %s: build the app into it first." % derived)

catalogs = collections.defaultdict(dict)  # catalog path -> {key: comment}
for extraction in extractions:
    data = json.load(open(extraction))
    parts = os.path.relpath(data["source"], root).split("/")
    if parts[:2] == ["App", "Marionette"]:
        catalog = "App/Marionette/Resources/Localizable.xcstrings"
    elif parts[0] == "Packages" and len(parts) > 3 and parts[2] == "Sources":
        catalog = "/".join(parts[:4]) + "/Resources/Localizable.xcstrings"
    else:
        continue
    for table, entries in data.get("tables", {}).items():
        if table != "Localizable":
            print("warning: table %s in %s is not synchronised" % (table, "/".join(parts)))
            continue
        for entry in entries:
            catalogs[catalog].setdefault(entry["key"], entry.get("comment") or "")

for catalog, extracted in sorted(catalogs.items()):
    path = os.path.join(root, catalog)
    if not os.path.exists(path):
        print("warning: %d strings and no catalog at %s" % (len(extracted), catalog))
        continue
    contents = json.load(open(path))
    strings = contents.get("strings", {})
    added = [key for key in extracted if key not in strings]
    for key, comment in extracted.items():
        entry = strings.setdefault(key, {})
        if comment and "comment" not in entry:
            entry["comment"] = comment
    removed = 0
    for key in [key for key in strings if key not in extracted]:
        if strings[key].get("localizations"):
            print("  stale, kept for its translations: %r" % key)
        else:
            del strings[key]
            removed += 1
    contents["strings"] = dict(sorted(strings.items(), key=lambda item: item[0].lower()))
    with open(path, "w") as output:
        json.dump(contents, output, indent=2, ensure_ascii=False, separators=(",", " : "))
        output.write("\n")
    print("%4d strings (+%d, -%d)  %s" % (len(strings), len(added), removed, catalog))
