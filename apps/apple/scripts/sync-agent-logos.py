#!/usr/bin/env python3
"""Copy Mindwire's original harness SVGs and export iOS-compatible vector assets."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


IOS = Path(__file__).resolve().parents[1]
ORIGINALS = IOS / "AgentArtwork"
CATALOG = IOS / "Mindwire/Resources/Assets.xcassets"
LOGOS = {
    "agent-codex": "codex-color.svg",
    "agent-claude-code": "claude-color.svg",
    "agent-grok": "grok.svg",
    "agent-opencode": "opencode.svg",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--daemon-repo", type=Path, default=IOS.parents[1],
        help="Refresh the originals from this Mindwire checkout before exporting.",
    )
    args = parser.parse_args()
    converter = shutil.which("rsvg-convert")
    if not converter:
        parser.error("rsvg-convert is required; install it with brew install librsvg")

    if args.daemon_repo:
        source = args.daemon_repo / "apps/web/public/logos"
        for filename in LOGOS.values():
            if not (source / filename).is_file():
                parser.error(f"Missing daemon artwork: {source / filename}")
        ORIGINALS.mkdir(exist_ok=True)
        for filename in LOGOS.values():
            shutil.copyfile(source / filename, ORIGINALS / filename)

    for asset, filename in LOGOS.items():
        imageset = CATALOG / f"{asset}.imageset"
        output = imageset / f"{asset}.pdf"
        # Preserve the artwork, gradient, transparency, and 24-point viewBox.
        # CoreSVG misrenders the compact arc syntax in the original Codex SVG.
        subprocess.run([
            converter, "--format", "pdf", "--width", "24", "--height", "24",
            "--dpi-x", "72", "--dpi-y", "72", "--output", str(output),
            str(ORIGINALS / filename),
        ], check=True, env={**os.environ, "SOURCE_DATE_EPOCH": "0"})
        contents_path = imageset / "Contents.json"
        contents = json.loads(contents_path.read_text())
        contents["images"] = [{"idiom": "universal", "filename": output.name}]
        contents_path.write_text(json.dumps(contents, indent=2) + "\n")
        print(f"{filename} -> {output.relative_to(IOS)}")


if __name__ == "__main__":
    main()
