#!/usr/bin/env python3

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"invalid profile: {message}")


def scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def parse_routing(path: Path) -> dict[str, str]:
    roles: dict[str, str] = {}
    for line in path.read_text().splitlines():
        match = re.match(
            r"\| `([^`]+)` \| (partition|replicate) \| (?:perform|unavailable) \|",
            line,
        )
        if match:
            roles[match.group(1)] = match.group(2)
    if not roles:
        fail(f"no roles found in {path}")
    return roles


@dataclass
class Route:
    execution: str | None = None
    workers_declared: bool = False
    workers: list[dict[str, str]] = field(default_factory=list)


@dataclass
class Profile:
    version: str | None = None
    host: str | None = None
    intent: dict[str, str] = field(default_factory=dict)
    delegation: dict[str, str] = field(default_factory=dict)
    roles: dict[str, Route] = field(default_factory=dict)


def parse_profile(path: Path) -> Profile:
    profile = Profile()
    section = ""
    current_role: str | None = None
    current_worker: dict[str, str] | None = None

    for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        top = re.fullmatch(r"([a-z][a-z0-9-]*):(?:\s*(.*))?", line)
        if top:
            key, value = top.groups()
            if key in {"intent", "delegation", "roles"} and not value:
                section = key
                current_role = None
                current_worker = None
            elif key in {"version", "host"} and value:
                if getattr(profile, key) is not None:
                    fail(f"duplicate top-level entry: {key}")
                setattr(profile, key, scalar(value))
                section = ""
            else:
                fail(f"unsupported top-level entry on line {line_number}: {key}")
            continue

        if section in {"intent", "delegation"}:
            match = re.fullmatch(r"  ([a-z][a-z0-9-]*):\s*(.+)", line)
            if not match:
                fail(f"invalid {section} entry on line {line_number}")
            target = profile.intent if section == "intent" else profile.delegation
            if match.group(1) in target:
                fail(f"duplicate {section} entry: {match.group(1)}")
            target[match.group(1)] = scalar(match.group(2))
            continue

        if section == "roles":
            role_match = re.fullmatch(r"  ([a-z][a-z0-9-]*):", line)
            if role_match:
                current_role = role_match.group(1)
                if current_role in profile.roles:
                    fail(f"duplicate role: {current_role}")
                profile.roles[current_role] = Route()
                current_worker = None
                continue
            if current_role is None:
                fail(f"role field without a role on line {line_number}")
            execution_match = re.fullmatch(r"    execution:\s*(\S+)", line)
            if execution_match:
                if profile.roles[current_role].execution is not None:
                    fail(f"duplicate execution for role: {current_role}")
                profile.roles[current_role].execution = scalar(execution_match.group(1))
                current_worker = None
                continue
            if line == "    workers:":
                if profile.roles[current_role].workers_declared:
                    fail(f"duplicate workers list for role: {current_role}")
                profile.roles[current_role].workers_declared = True
                current_worker = None
                continue
            worker_match = re.fullmatch(
                r"      - (model|inherit-parent):\s*(\S+)", line
            )
            if worker_match:
                if not profile.roles[current_role].workers_declared:
                    fail(f"worker entry before workers list on line {line_number}")
                current_worker = {
                    worker_match.group(1): scalar(worker_match.group(2))
                }
                profile.roles[current_role].workers.append(current_worker)
                continue
            reasoning_match = re.fullmatch(r"        reasoning:\s*(\S+)", line)
            if reasoning_match and current_worker is not None:
                if "reasoning" in current_worker:
                    fail(f"duplicate reasoning on line {line_number}")
                current_worker["reasoning"] = scalar(reasoning_match.group(1))
                continue
            fail(f"invalid role entry on line {line_number}")

        fail(f"entry outside a section on line {line_number}")

    return profile


def positive_integer_or(value: str | None, sentinel: str, name: str) -> int | None:
    if value == sentinel:
        return None
    if value is None or not value.isdigit() or int(value) < 1:
        fail(f"{name} must be a positive integer or {sentinel}")
    return int(value)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: validate-profile.py <profile.yaml> <ROUTING.md>")

    profile = parse_profile(Path(sys.argv[1]))
    expected_roles = parse_routing(Path(sys.argv[2]))

    if profile.version != "2":
        fail("version must be 2")
    if profile.host is None or not re.fullmatch(r"[a-z][a-z0-9-]*", profile.host):
        fail("host must be a non-empty slug")
    if set(profile.intent) != {"optimization", "budget"}:
        fail("intent must contain exactly optimization and budget")

    mode = profile.delegation.get("mode")
    if mode == "disabled":
        if set(profile.delegation) != {"mode"}:
            fail("disabled delegation must not define worker limits")
        if profile.roles:
            fail("disabled delegation must not define roles")
        print("valid profile: delegation disabled")
        return
    if mode != "enabled":
        fail("delegation.mode must be enabled or disabled")
    if set(profile.delegation) != {
        "mode",
        "max-workers-per-task",
        "max-concurrent-workers",
        "max-delegation-depth",
    }:
        fail("enabled delegation must define exactly all delegation limits")

    task_limit = positive_integer_or(
        profile.delegation.get("max-workers-per-task"),
        "unlimited",
        "max-workers-per-task",
    )
    positive_integer_or(
        profile.delegation.get("max-concurrent-workers"),
        "host-limit",
        "max-concurrent-workers",
    )
    positive_integer_or(
        profile.delegation.get("max-delegation-depth"),
        "unlimited",
        "max-delegation-depth",
    )

    for role, route in profile.roles.items():
        if route.execution == "coordinator":
            if route.workers_declared:
                fail(f"{role} uses coordinator execution and must not define workers")
            continue
        if route.execution != "workers":
            fail(f"{role}.execution must be coordinator or workers")
        if not route.workers:
            fail(f"{role} uses workers execution and needs a non-empty roster")
        if task_limit is not None and len(route.workers) > task_limit:
            fail(f"{role} roster exceeds max-workers-per-task")
        for index, worker in enumerate(route.workers, start=1):
            if worker == {"inherit-parent": "true"}:
                continue
            if set(worker) != {"model", "reasoning"}:
                fail(
                    f"{role} worker {index} must define model with reasoning "
                    "or inherit-parent: true"
                )
            if not worker["model"] or not worker["reasoning"]:
                fail(f"{role} worker {index} has an empty model or reasoning")

    missing = sorted(expected_roles.keys() - profile.roles.keys())
    extra = sorted(profile.roles.keys() - expected_roles.keys())
    if missing:
        fail(f"missing roles: {', '.join(missing)}")
    if extra:
        fail(f"unknown roles: {', '.join(extra)}")

    print(f"valid profile: delegation enabled, {len(profile.roles)} roles")


if __name__ == "__main__":
    main()
