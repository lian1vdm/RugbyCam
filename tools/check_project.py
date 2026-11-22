#!/usr/bin/env python3
"""
check_project.py - sanity checks that need no Mac.

1. Parses both project.pbxproj files and checks that every reference points to
   an object that exists, that every Swift file on disk is compiled exactly
   once, and that every file the project names exists on disk.
2. Checks the scheme files and Info.plist are well-formed.
3. Runs a structural check over every Swift file: balanced brackets, closed
   strings and comments. It is not a compiler; it only catches gross slips.

Run:  python3 tools/check_project.py
"""

import os
import plistlib
import re
import sys
import xml.dom.minidom

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBLEMS = []


def problem(text):
    PROBLEMS.append(text)
    print("  PROBLEM:", text)


# ---------------------------------------------------------------- pbxproj parser

class Parser:
    def __init__(self, text):
        self.t = text
        self.i = 0

    def skip(self):
        t = self.t
        while self.i < len(t):
            c = t[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif t.startswith("/*", self.i):
                end = t.find("*/", self.i + 2)
                if end < 0:
                    raise ValueError("unterminated comment at %d" % self.i)
                self.i = end + 2
            elif t.startswith("//", self.i):
                end = t.find("\n", self.i)
                self.i = len(t) if end < 0 else end + 1
            else:
                break

    def expect(self, ch):
        self.skip()
        if self.t[self.i] != ch:
            raise ValueError("expected %r at %d, found %r" % (ch, self.i, self.t[self.i:self.i + 20]))
        self.i += 1

    def value(self):
        self.skip()
        c = self.t[self.i]
        if c == "{":
            self.i += 1
            d = {}
            while True:
                self.skip()
                if self.t[self.i] == "}":
                    self.i += 1
                    return d
                key = self.value()
                self.expect("=")
                d[key] = self.value()
                self.expect(";")
        if c == "(":
            self.i += 1
            items = []
            while True:
                self.skip()
                if self.t[self.i] == ")":
                    self.i += 1
                    return items
                items.append(self.value())
                self.skip()
                if self.t[self.i] == ",":
                    self.i += 1
        if c == '"':
            self.i += 1
            buf = []
            while self.t[self.i] != '"':
                if self.t[self.i] == "\\":
                    self.i += 1
                buf.append(self.t[self.i])
                self.i += 1
            self.i += 1
            return "".join(buf)
        m = re.compile(r"[A-Za-z0-9_./$]+").match(self.t, self.i)
        if not m:
            raise ValueError("unexpected character %r at %d" % (c, self.i))
        self.i = m.end()
        return m.group(0)


ID = re.compile(r"^[0-9A-F]{24}$")


def check_pbxproj(project_name, expect_package):
    path = os.path.join(ROOT, project_name + ".xcodeproj", "project.pbxproj")
    print("Checking", os.path.relpath(path, ROOT))
    text = open(path, encoding="utf-8").read()
    if not text.startswith("// !$*UTF8*$!"):
        problem("missing the UTF8 header line")
    parser = Parser(text[text.index("{"):])
    try:
        doc = parser.value()
    except (ValueError, IndexError) as e:
        problem("project file does not parse: %s" % e)
        return None
    objects = doc["objects"]
    if doc["rootObject"] not in objects:
        problem("rootObject is missing")

    def refs(v):
        if isinstance(v, str):
            if ID.match(v):
                yield v
        elif isinstance(v, list):
            for x in v:
                yield from refs(x)
        elif isinstance(v, dict):
            for k, x in v.items():
                if ID.match(k):
                    yield k
                yield from refs(x)

    for oid, obj in objects.items():
        if "isa" not in obj:
            problem("object %s has no isa" % oid)
        for r in refs(obj):
            if r not in objects:
                problem("object %s (%s) refers to missing object %s" % (oid, obj.get("isa"), r))

    # Walk the groups to find each file's path on disk.
    parents = {}
    for oid, obj in objects.items():
        if obj.get("isa") == "PBXGroup":
            for child in obj.get("children", []):
                parents[child] = oid

    def disk_path(oid):
        parts = []
        while oid is not None:
            obj = objects[oid]
            if "path" in obj:
                parts.append(obj["path"])
            oid = parents.get(oid)
        return os.path.join(ROOT, *reversed(parts))

    compiled = {}
    for oid, obj in objects.items():
        if obj.get("isa") == "PBXSourcesBuildPhase":
            for bf in obj["files"]:
                ref = objects[bf]["fileRef"]
                compiled[disk_path(ref)] = compiled.get(disk_path(ref), 0) + 1
    for oid, obj in objects.items():
        if obj.get("isa") == "PBXFileReference" and obj.get("sourceTree") == "<group>":
            if not os.path.exists(disk_path(oid)):
                problem("file named in the project is not on disk: %s" % disk_path(oid))
    on_disk = []
    for folder, _, files in os.walk(os.path.join(ROOT, "RugbyCam")):
        on_disk += [os.path.join(folder, f) for f in files if f.endswith(".swift")]
    for f in on_disk:
        if compiled.get(f, 0) != 1:
            problem("%s is compiled %d times (should be once)" % (os.path.relpath(f, ROOT), compiled.get(f, 0)))
    for f in compiled:
        if f not in on_disk:
            problem("project compiles a file that is not on disk: %s" % f)

    targets = [o for o in objects.values() if o.get("isa") == "PBXNativeTarget"]
    if len(targets) != 1:
        problem("expected exactly one target")
    packages = [o for o in objects.values() if o.get("isa") == "XCRemoteSwiftPackageReference"]
    if expect_package and len(packages) != 1:
        problem("expected the HaishinKit package reference")
    if not expect_package and packages:
        problem("the Lite project must not reference a package")
    for o in objects.values():
        if o.get("isa") == "XCBuildConfiguration" and "INFOPLIST_FILE" in o["buildSettings"]:
            if not os.path.exists(os.path.join(ROOT, o["buildSettings"]["INFOPLIST_FILE"])):
                problem("INFOPLIST_FILE does not exist")
    print("  %d objects, %d Swift files compiled, %d package(s)" % (len(objects), len(compiled), len(packages)))
    target_ids = [k for k, o in objects.items() if o.get("isa") == "PBXNativeTarget"]
    return target_ids[0] if target_ids else None


def check_scheme(project_name, scheme_name, target_id):
    path = os.path.join(ROOT, project_name + ".xcodeproj", "xcshareddata", "xcschemes", scheme_name + ".xcscheme")
    print("Checking", os.path.relpath(path, ROOT))
    try:
        dom = xml.dom.minidom.parse(path)
    except Exception as e:
        problem("scheme is not valid XML: %s" % e)
        return
    refs = dom.getElementsByTagName("BuildableReference")
    if not refs:
        problem("scheme has no BuildableReference")
    for r in refs:
        if r.getAttribute("BlueprintIdentifier") != target_id:
            problem("scheme points at a target that does not exist")
        if r.getAttribute("ReferencedContainer") != "container:%s.xcodeproj" % project_name:
            problem("scheme points at the wrong project")


# ---------------------------------------------------------------- Swift structure

def check_swift(path):
    text = open(path, encoding="utf-8").read()
    rel = os.path.relpath(path, ROOT)
    stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    i, line = 0, 1
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    if text[i] == "\n":
                        line += 1
                    i += 1
            if depth:
                problem("%s: comment never closed" % rel)
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            if end < 0:
                problem("%s:%d: multi-line string never closed" % (rel, line))
                return
            line += text.count("\n", i, end)
            i = end + 3
        elif c == '"':
            # A string literal. Interpolations \( ... ) may contain brackets and strings.
            i += 1
            depth = 0
            while i < n:
                ch = text[i]
                if ch == "\\" and depth == 0:
                    if i + 1 < n and text[i + 1] == "(":
                        depth = 1
                        i += 2
                        continue
                    i += 2
                    continue
                if depth > 0:
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                    elif ch == '"':
                        # nested string inside an interpolation
                        j = text.find('"', i + 1)
                        if j < 0:
                            break
                        i = j
                    i += 1
                    continue
                if ch == '"':
                    break
                if ch == "\n":
                    problem("%s:%d: string never closed on its line" % (rel, line))
                    return
                i += 1
            i += 1
        elif c in "([{":
            stack.append((c, line))
            i += 1
        elif c in ")]}":
            if not stack or stack[-1][0] != pairs[c]:
                problem("%s:%d: unexpected %r" % (rel, line, c))
                return
            stack.pop()
            i += 1
        else:
            i += 1
    for c, opened in stack:
        problem("%s:%d: %r is never closed" % (rel, opened, c))
    for k, text_line in enumerate(text.split("\n"), 1):
        if "\t" in text_line:
            problem("%s:%d: tab character (the files use spaces)" % (rel, k))
            break


def main():
    lite = check_pbxproj("RugbyCam-Lite", expect_package=False)
    full = check_pbxproj("RugbyCam", expect_package=True)
    if lite:
        check_scheme("RugbyCam-Lite", "RugbyCam-Lite", lite)
    if full:
        check_scheme("RugbyCam", "RugbyCam", full)

    print("Checking RugbyCam/Info.plist")
    try:
        info = plistlib.load(open(os.path.join(ROOT, "RugbyCam", "Info.plist"), "rb"))
        for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                    "NSBluetoothAlwaysUsageDescription", "NSPhotoLibraryAddUsageDescription",
                    "CFBundleIdentifier", "CFBundleExecutable", "UILaunchScreen"):
            if key not in info:
                problem("Info.plist lacks %s" % key)
    except Exception as e:
        problem("Info.plist does not parse: %s" % e)

    print("Checking Swift file structure")
    count = 0
    for folder, _, files in os.walk(os.path.join(ROOT, "RugbyCam")):
        for f in sorted(files):
            if f.endswith(".swift"):
                check_swift(os.path.join(folder, f))
                count += 1
    print("  %d Swift files looked at" % count)

    print()
    print("RESULT:", "no problems found" if not PROBLEMS else "%d problem(s)" % len(PROBLEMS))
    return 1 if PROBLEMS else 0


if __name__ == "__main__":
    sys.exit(main())
