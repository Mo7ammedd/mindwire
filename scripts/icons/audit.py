#!/usr/bin/env python3
"""Verify the bundled artwork and prevent a second UI icon system from creeping in."""
from pathlib import Path
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/apple/Mindwire"
ASSETS = APP / "Resources/InterfaceIcons.xcassets"
CATALOG = json.loads((ROOT / "scripts/icons/catalog.json").read_text())["icons"]


def audit():
    errors = []
    hashes = set()
    png_bytes = 0
    for name, spec in CATALOG.items():
        directory = ASSETS / f"ui-{name}.imageset"
        try:
            contents = json.loads((directory / "Contents.json").read_text())
            image = directory / spec["file"]
            data = image.read_bytes()
            png_bytes += len(data)
            digest = hashlib.sha256(data).hexdigest()
            if digest != spec["sha256"]:
                errors.append(f"{name}: original artwork checksum differs")
            if digest in hashes:
                errors.append(f"{name}: duplicate artwork; use the existing ID")
            hashes.add(digest)
            if [entry.get("filename") for entry in contents["images"]] != [spec["file"]]:
                errors.append(f"{name}: asset filename differs from the reviewed catalog")
            if {path.name for path in directory.glob("*.png")} != {spec["file"]}:
                errors.append(f"{name}: remove unreferenced artwork from the asset set")
            if contents["properties"].get("template-rendering-intent") != "template":
                errors.append(f"{name}: missing native template tinting")
        except (KeyError, OSError, ValueError) as error:
            errors.append(f"{name}: {error}")
    expected = {f"ui-{name}.imageset" for name in CATALOG}
    actual = {directory.name for directory in ASSETS.glob("*.imageset")}
    if expected != actual:
        errors.append(f"Unlisted or missing assets: {sorted(expected ^ actual)}")
    generated = (APP / "DesignSystem/AppIconName.swift").read_text()
    declarations = set(re.findall(r"^    case (\w+)$", generated, re.MULTILINE))
    if declarations != set(CATALOG):
        errors.append("Generated Swift catalog is stale; run scripts/icons/import.swift")
    # These are app-owned glyphs. iOS itself continues to own navigation chevrons,
    # alerts, keyboard chrome, progress spinners, and text-selection handles.
    for path in APP.rglob("*.swift"):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            # Keep Apple's native brand mark for macOS workspace identities.
            if (path == APP / "Features/Workspace/WorkspaceRow.swift"
                    and line.strip() == 'Image(systemName: "apple.logo")'):
                continue
            if re.search(r"\b(?:Image|UIImage)\s*\(\s*systemName:|\bsystemImage:", line):
                errors.append(f"{path.relative_to(ROOT)}:{number}: use AppIcon or Label(icon:)")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Verified {len(CATALOG)} bundled icons ({png_bytes:,} PNG bytes), original checksums, unique assets, template tinting, and app-wide catalog use.")
    return 0


if __name__ == "__main__":
    raise SystemExit(audit())
