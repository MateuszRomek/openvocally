#!/usr/bin/env python3

import re
from pathlib import Path


ROOT = Path.cwd()
ROUTING = ROOT / ".agents/agent-mode/ROUTING.md"
HOST = ROOT / ".agents/agent-mode/HOST-COMPATIBILITY.md"
ASSET_ROOT = ROOT / ".agents/skills/setup-agent-mode/assets/agent-mode"


def fail(messages: list[str]) -> None:
    details = "\n".join(f"- {message}" for message in messages)
    raise SystemExit(f"routing audit failed:\n{details}")


def catalog_roles(text: str) -> set[str]:
    return set(
        re.findall(
            r"^\| `([^`]+)` \| (?:partition|replicate) \| (?:perform|unavailable) \|",
            text,
            re.MULTILINE,
        )
    )


def main() -> None:
    errors: list[str] = []
    routing_text = ROUTING.read_text()
    roles = catalog_roles(routing_text)
    if not roles:
        errors.append("ROUTING.md contains no parseable roles")

    for name in ("ROUTING.md", "HOST-COMPATIBILITY.md"):
        current = ROOT / ".agents/agent-mode" / name
        asset = ASSET_ROOT / name
        if current.read_bytes() != asset.read_bytes():
            errors.append(f"{current} differs from packaged asset {asset}")

    central = routing_text + "\n" + HOST.read_text()
    for pattern, label in (
        (r"\|\s*(?:single|panel)\s*\|", "obsolete single/panel route shape"),
        (r"max-panel-workers", "obsolete panel limit"),
        (r"without configuration", "implicit unconfigured fallback"),
        (r"otherwise inherit", "implicit inheritance fallback"),
    ):
        if re.search(pattern, central, re.IGNORECASE):
            errors.append(f"central contract contains {label}")

    consumer_paths = sorted(
        set((ROOT / ".agents/skills").glob("*/SKILL.md"))
        | set((ROOT / ".agents/skills/agent-mode/playbooks").glob("*.md"))
    )
    role_token = re.compile(r"`(" + "|".join(map(re.escape, sorted(roles))) + r")`")
    forbidden = (
        (re.compile(r"\b(?:otherwise|when absent|if absent)\b[^\n]*\binherit", re.I), "implicit inheritance"),
        (re.compile(r"\bwithout configuration\b", re.I), "unconfigured fallback"),
        (re.compile(r"\bmissing roles?\b[^\n]*\binherit", re.I), "missing-role inheritance"),
        (re.compile(r"\bdifferent model family\b", re.I), "skill-selected model family"),
        (re.compile(r"\breasoning efforts?\b[^\n]*(?:minimum|escalat)", re.I), "skill-selected reasoning escalation"),
        (
            re.compile(
                r"\b(?:spawn|launch|fire|delegate)(?:s|ed|ing)?\s+[^\n]{0,80}"
                r"\b(?:subagents?|workers?|reviewers?|investigators?|judges?|candidates?)\b",
                re.I,
            ),
            "direct worker creation outside the routing contract",
        ),
        (
            re.compile(
                r"\b(?:spawn|launch|fire|run|add|assign|delegate|require|use)\s+"
                r"[^\n]{0,60}\b(?:one|two|three|four|five|\d+|N)\s+"
                r"(?:[a-z-]+\s+){0,2}"
                r"(?:subagents?|workers?|reviewers?|investigators?|judges?|candidates?)\b",
                re.I,
            ),
            "hardcoded worker cardinality",
        ),
    )

    for path in consumer_paths:
        if path.parent.name == "setup-agent-mode":
            continue
        text = path.read_text()
        if not role_token.search(text):
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            for pattern, label in forbidden:
                if pattern.search(line):
                    errors.append(f"{path.relative_to(ROOT)}:{line_number}: {label}")

    if errors:
        fail(errors)
    print(f"routing audit passed: {len(roles)} roles")


if __name__ == "__main__":
    main()
