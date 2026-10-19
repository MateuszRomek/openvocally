#!/usr/bin/env python3
"""Fail when an OpenVocallyKit module marks a symbol public that no other module uses.

A type or top-level function counts as used when its name appears in a consumer.
A member counts as used when `.name` appears in a consumer. Consumers are the other
modules, their tests, the app and the Swift packages under scripts/. A module's own
tests do not count, because they use @testable import.

Usage: scripts/check-public-api.py
"""

import re
import subprocess
import sys
from pathlib import Path

SOURCES = Path("OpenVocallyKit/Sources")
TESTS = Path("OpenVocallyKit/Tests")

# Members that must be public because they satisfy a protocol requirement.
WITNESSES = {
    "body", "id", "description", "debugDescription", "errorDescription", "failureReason",
    "recoverySuggestion", "hash", "encode", "rawValue", "allCases", "makeBody", "makeNSView",
    "updateNSView", "dismantleNSView", "makeCoordinator", "sizeThatFits", "placeSubviews",
    "makeCache", "updateCache", "path",
    "animatableData", "defaultValue", "reduce", "makeIterator", "next", "startIndex",
    "endIndex", "index", "subscript", "callAsFunction", "unownedExecutor", "transferRepresentation",
}

DECL = re.compile(
    r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*"
    r"(?:(?:nonisolated|static|class|final|override|mutating|nonmutating|convenience|required|indirect|lazy|dynamic)\s+)*"
    r"(?:public|open)(?:\(set\))?\s+"
    r"(?:(?:nonisolated|static|class|final|override|mutating|nonmutating|convenience|required|indirect|lazy|dynamic|private\(set\)|internal\(set\))\s+)*"
    r"(?:(func|var|let|struct|class|enum|actor|protocol|typealias)\s+`?([A-Za-z_]\w*)|init\b|subscript\b)"
)
MEMBER = re.compile(r"^\s*(?:static\s+|mutating\s+)*(?:case|func|var|init|subscript|associatedtype)\b")
BLOCK_STRING = re.compile(r'""".*?"""', re.S)
STRING = re.compile(r'"(?:\\.|[^"\\\n])*"')
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//.*$", re.M)
INTERPOLATION = re.compile(r"\\\(([^)]*)\)")


def blank(match):
    return "\n" * match.group(0).count("\n")


def code(path):
    text = STRING.sub(literal, BLOCK_STRING.sub(blank, path.read_text()))
    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub(blank, text))


def literal(match):
    return '"' + " ".join(INTERPOLATION.findall(match.group(0))) + '"'


def declarations(text):
    lines = text.splitlines()
    depth = 0
    requirements = []
    for number, line in enumerate(lines, 1):
        match = DECL.match(line)
        if match:
            signature = [line[match.end() :]]
            for following in lines[number : number + 8]:
                opened = "".join(signature)
                if opened.count("(") <= opened.count(")"):
                    break
                signature.append(following)
            yield number, match.group(1), match.group(2), depth == 0, "\n".join(signature)
            if match.group(1) in {"protocol", "enum"}:
                requirements.append(depth)
        elif requirements and depth == requirements[-1] + 1 and MEMBER.match(line):
            yield number, "requirement", None, False, line
        depth += line.count("{") - line.count("}")
        while requirements and depth <= requirements[-1]:
            requirements.pop()


def main():
    if len(sys.argv) > 1:
        print(__doc__.strip())
        return 0
    tracked = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.swift"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    files = [Path(f) for f in tracked if not f.startswith("prototypes/") and Path(f).exists()]
    texts = {f: code(f) for f in files}
    unused = []
    for module in sorted(p for p in SOURCES.iterdir() if p.is_dir()):
        own = [f for f in files if module in f.parents]
        own_tests = TESTS / f"{module.name}Tests"
        consumers = "\n".join(t for f, t in texts.items() if module not in f.parents and own_tests not in f.parents)
        decls = [(path, *d) for path in own for d in declarations(texts[path])]
        for path, number, kind, name, top_level, _ in decls:
            if name is None or name in WITNESSES:
                continue
            exposed = "\n".join(sig for p, n, *_, sig in decls if (p, n) != (path, number))
            requirements = "\n".join(sig for _, _, kind, *_, sig in decls if kind == "requirement")
            if top_level or kind in {"struct", "class", "enum", "actor", "protocol", "typealias"}:
                used = re.search(rf"\b{name}\b", consumers) or re.search(rf"\b{name}\b", exposed)
            else:
                used = re.search(rf"\.{name}\b", consumers + exposed) or re.search(
                    rf"\b(?:func|var|let)\s+{name}\b", requirements
                )
            if not used:
                unused.append(f"{path}:{number}: public {kind} {name}")
    if unused:
        print("\n".join(unused), file=sys.stderr)
        print(
            f"{len(unused)} public symbols are not used outside their module. Drop `public` "
            "(tests reach internal symbols through @testable import).",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
