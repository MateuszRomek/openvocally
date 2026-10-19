#!/usr/bin/env python3
"""Write the third-party attributions from scripts/attributions/components.json.

Checks the registry against what the app ships: the SwiftPM pins, the pinned speech
models, the whisper.cpp tag and the bundled sound files. Then writes
App/Resources/Credits.html (shown in the About panel) and the license texts in
App/Resources/Licenses.

Usage: scripts/attributions/generate.py [--fetch] [--check] [--resolved PATH]
                                        [--manifests PATH] [--whisper-script PATH]

  --fetch   Download the license and NOTICE texts from the registry's pinned URLs into
            App/Resources/Licenses. Without it the script makes no network calls.
  --check   Write nothing. Fail when a generated file is out of date.

After changing a dependency, model or sound, update components.json, then run
scripts/attributions/generate.py --fetch and commit the results.
"""

import argparse
import fnmatch
import html
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = ROOT / "scripts/attributions/components.json"
CREDITS = ROOT / "App/Resources/Credits.html"
LICENSES = ROOT / "App/Resources/Licenses"
ASSET_DIRS = ["App/Resources/Sounds"]
# Synthesized for this repository, so they ship under its license.
OWN_ASSETS = ["App/Resources/Sounds/cue-*.wav"]
LICENSE_URLS = {
    "Apache-2.0": "https://www.apache.org/licenses/LICENSE-2.0",
    "MIT": "https://opensource.org/license/mit",
    "BSD-2-Clause": "https://opensource.org/license/bsd-2-clause",
    "CC-BY-4.0": "https://creativecommons.org/licenses/by/4.0/",
}
FIX = "Edit scripts/attributions/components.json."


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--help", action="store_true")
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--resolved", type=Path, default=ROOT / "OpenVocallyKit/Package.resolved")
    parser.add_argument(
        "--manifests", type=Path, default=ROOT / "OpenVocallyKit/Sources/Models/ModelManifests.swift"
    )
    parser.add_argument(
        "--whisper-script", type=Path, default=ROOT / "scripts/whisper/build-xcframework.sh"
    )
    args = parser.parse_args()
    if args.help:
        print(__doc__.strip())
        return 0
    if args.fetch and args.check:
        return fail(["--fetch and --check cannot run together."])

    components = json.loads(REGISTRY.read_text())
    errors = validate(components, sources(args))
    if errors:
        return fail(errors)

    texts = fetch_texts(components) if args.fetch else None
    expected = {CREDITS: credits_html(components)}
    if args.check:
        return check(components, expected)
    for path, content in expected.items():
        path.write_text(content)
    if texts is not None:
        LICENSES.mkdir(exist_ok=True)
        for stale in set(LICENSES.iterdir()) - {LICENSES / name for name in texts}:
            stale.unlink()
        for name, content in texts.items():
            (LICENSES / name).write_bytes(content)
    missing = [name for name in license_files(components) if not (LICENSES / name).is_file()]
    if missing:
        return fail([f"Missing {', '.join(missing)}. Run scripts/attributions/generate.py --fetch."])
    return 0


def sources(args):
    """Every component the app ships, keyed by (kind, source), with its version."""
    found = {}
    for pin in json.loads(args.resolved.read_text())["pins"]:
        version = pin["state"].get("version") or pin["state"]["revision"]
        found[("package", pin["identity"])] = version
        found[("bundled", f"{pin['identity']}@{version}")] = None
    # The app target's packages resolve in the generated Xcode project, which is not committed,
    # so read their exact pins from project.yml.
    for url, version in re.findall(
        r"url: (\S+)\s+exactVersion: \"?([^\s\"]+)", (ROOT / "project.yml").read_text()
    ):
        identity = url.rstrip("/").removesuffix(".git").rsplit("/", 1)[-1].lower()
        found[("package", identity)] = version
        found[("bundled", f"{identity}@{version}")] = None
    manifest = args.manifests.read_text()
    for repository, revision in re.findall(
        r'repository: "([^"]+)",\s*revision: "([0-9a-f]+)"', manifest
    ):
        found[("model", repository)] = revision
    tag = re.search(r'^TAG="([^"]+)"', args.whisper_script.read_text(), re.M)
    if tag:
        found[("vendored", "whisper.cpp")] = tag.group(1)
    for directory in ASSET_DIRS:
        for path in sorted((ROOT / directory).iterdir()):
            relative = path.relative_to(ROOT).as_posix()
            if path.is_file() and not any(fnmatch.fnmatch(relative, own) for own in OWN_ASSETS):
                found[("asset", relative)] = None
    return found


def validate(components, found):
    errors = []
    ids = [component["id"] for component in components]
    for duplicate in sorted({i for i in ids if ids.count(i) > 1}):
        errors.append(f"Registry id {duplicate} appears more than once. {FIX}")
    covered = set()
    for component in components:
        kind, source = component["kind"], component["source"]
        if kind == "asset":
            keys = [key for key in found if key[0] == "asset" and fnmatch.fnmatch(key[1], source)]
            if not keys:
                errors.append(f"{component['id']}: {source} matches no file. Remove it. {FIX}")
            covered.update(keys)
            continue
        key = (kind, source)
        if key not in found:
            hint = (
                "Its parent package version changed: check what it bundles now, then update source."
                if kind == "bundled"
                else "Remove the entry or fix its source."
            )
            errors.append(f"{component['id']}: no shipped {kind} matches {source}. {hint} {FIX}")
            continue
        covered.add(key)
        if found[key] is not None and found[key] != component["version"]:
            errors.append(
                f"{component['id']}: registry version {component['version']} but the app ships "
                f"{found[key]}. Update version and the pinned text URLs. {FIX}"
            )
        if component["license"] not in LICENSE_URLS and "licenseUrl" not in component:
            errors.append(f"{component['id']}: add a licenseUrl for {component['license']}. {FIX}")
    for kind, source in sorted(set(found) - covered):
        if kind != "bundled":
            errors.append(f"No registry entry for the {kind} {source}. Add one. {FIX}")
    return errors


def license_files(components):
    return [f"{c['id']}-{text['file']}.txt" for c in components for text in c["texts"]]


def fetch_texts(components):
    texts = {}
    for component in components:
        for text in component["texts"]:
            result = subprocess.run(["curl", "-fsSL", text["url"]], capture_output=True)
            if result.returncode != 0:
                sys.exit(f"Could not download {text['url']}: {result.stderr.decode().strip()}")
            texts[f"{component['id']}-{text['file']}.txt"] = result.stdout
    return texts


def license_url(component):
    return component.get("licenseUrl") or LICENSE_URLS[component["license"]]


def version_label(component):
    version = component["version"]
    if version is None:
        return None
    return version[:7] if re.fullmatch(r"[0-9a-f]{40}", version) else version


def credits_html(components):
    blocks = []
    for component in components:
        version = version_label(component)
        title = html.escape(component["name"]) + (f" {html.escape(version)}" if version else "")
        blocks.append(
            f'<p><b><a href="{html.escape(component["url"])}">{title}</a></b><br>\n'
            f"{html.escape(component['copyright'])}<br>\n"
            f'License: <a href="{html.escape(license_url(component))}">'
            f"{html.escape(component['license'])}</a></p>"
        )
    return (
        "<!DOCTYPE html>\n"
        "<!-- Generated by scripts/attributions/generate.py. Do not edit. -->\n"
        '<html><head><meta charset="utf-8"></head>\n'
        '<body style="font-family: -apple-system; font-size: 11px; text-align: center">\n'
        "<p>OpenVocally is free software under the GNU General Public License, version 3 "
        "only. It includes the components below. Their full license texts are in "
        "Contents/Resources/Licenses inside the app.</p>\n" + "\n".join(blocks) + "\n</body></html>\n"
    )


def check(components, expected):
    errors = []
    for path, content in expected.items():
        if not path.is_file() or path.read_text() != content:
            errors.append(f"{path.relative_to(ROOT)} is out of date.")
    wanted = set(license_files(components))
    present = {path.name for path in LICENSES.iterdir()} if LICENSES.is_dir() else set()
    errors += [f"App/Resources/Licenses/{name} is missing." for name in sorted(wanted - present)]
    errors += [f"App/Resources/Licenses/{name} is not in the registry." for name in sorted(present - wanted)]
    if errors:
        errors.append("Run scripts/attributions/generate.py --fetch and commit the results.")
        return fail(errors)
    return 0


def fail(errors):
    for error in errors:
        print(error, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
