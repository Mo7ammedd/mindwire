#!/usr/bin/env python3
"""Capture real simulator screens, including native status bars, with offline test data.

Example:
  python3 scripts/app-store/capture.py --device <simulator-udid> \
    --derived-data /tmp/MindwireStoreBuild --output apps/apple/artifacts/app-store/raw/ipad
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="A dedicated iOS simulator UDID")
    parser.add_argument("--derived-data", type=Path, default=Path(tempfile.gettempdir()) / "MindwireStoreBuild")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--kind", choices=["iphone", "ipad"], default="iphone")
    parser.add_argument("--native-size", help="Expected upright capture size, e.g. 1320x2868; defaults to iPhone 17 Pro Max / iPad Pro 13-inch")
    parser.add_argument("--scenes", help="Comma-separated subset: chat,projects,review,files,desktop,switch")
    parser.add_argument("--themes", default="dark,light")
    args = parser.parse_args()
    try:
        width, height = map(int, (args.native_size or ("1320x2868" if args.kind == "iphone" else "2752x2064")).lower().split("x"))
        if min(width, height) <= 0:
            raise ValueError()
    except ValueError:
        parser.error("--native-size must be WIDTHxHEIGHT in positive pixels")
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    destination = f"platform=iOS Simulator,id={args.device}"
    if not args.skip_build:
        run("xcodegen", "generate", "--spec", str(root / "apps/apple/project.yml"))
        with (output / "build.log").open("w") as log:
            run("xcodebuild", "build-for-testing", "-project", str(root / "apps/apple/Mindwire.xcodeproj"),
                "-scheme", "Mindwire", "-destination", destination, "-derivedDataPath", str(args.derived_data),
                "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", stdout=log, stderr=subprocess.STDOUT)

    products = args.derived_data / "Build/Products"
    candidates = sorted(products.glob("Mindwire_iphonesimulator*.xctestrun"), key=lambda p: p.stat().st_mtime)
    if not candidates:
        raise SystemExit("No simulator test build found. Run without --skip-build first.")
    config = plistlib.loads(candidates[-1].read_bytes())
    staging = Path(tempfile.mkdtemp(prefix="mindwire-store-capture-"))
    capture_environment = {
        "MINDWIRE_STORE_CAPTURE_DIR": str(staging),
        "MINDWIRE_STORE_CAPTURE": "1",
        "MINDWIRE_STORE_DEVICE": args.kind,
        "MINDWIRE_STORE_THEMES": args.themes,
        "MINDWIRE_STORE_PIXEL_WIDTH": str(width),
        "MINDWIRE_STORE_PIXEL_HEIGHT": str(height),
    }
    if args.scenes:
        capture_environment["MINDWIRE_STORE_SCENES"] = args.scenes
    targets = [config["MindwireUITests"]] if "MindwireUITests" in config else [
        target for configuration in config["TestConfigurations"] for target in configuration["TestTargets"]
        if target.get("BlueprintName") == "MindwireUITests"
    ]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(capture_environment)
        target.setdefault("TestingEnvironmentVariables", {}).update(capture_environment)
    test_run = products / f"Mindwire-store-{uuid.uuid4()}.xctestrun"
    test_run.write_bytes(plistlib.dumps(config))

    run("xcrun", "simctl", "status_bar", args.device, "override", "--time", "9:41", "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--batteryState", "discharging", "--batteryLevel", "100")
    completed = set()
    process = None
    try:
        with (output / "capture.log").open("w") as log:
            process = subprocess.Popen([
                "xcodebuild", "test-without-building", "-xctestrun", str(test_run), "-destination", destination,
                "-only-testing:MindwireUITests/AppStoreScreenshots/testCaptureAppStoreScreenshots",
                "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
                "-resultBundlePath", str(output / f"Capture-{int(time.time())}.xcresult")
            ], stdout=log, stderr=subprocess.STDOUT)
            started = time.monotonic()
            while process.poll() is None:
                if time.monotonic() - started > 600:
                    raise TimeoutError("Screenshot test exceeded ten minutes; see capture.log.")
                for capture in staging.glob("*.png"):
                    name = capture.stem
                    if name not in completed:
                        completed.add(name)
                        print(f"Captured {name}", flush=True)
                time.sleep(0.15)
            if process.returncode:
                raise RuntimeError(f"Capture tests failed ({process.returncode}); see {output / 'capture.log'}")
        for screenshot in staging.glob("*.png"):
            shutil.copy2(screenshot, output / screenshot.name)
        devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))["devices"]
        device = next((item for items in devices.values() for item in items if item["udid"] == args.device), {})
        (output / "capture.json").write_text(json.dumps({
            "device": args.device, "device_name": device.get("name"), "device_type": device.get("deviceTypeIdentifier"),
            "native_size": [width, height], "screens": sorted(path.stem for path in output.glob("*.png")),
            "last_run": sorted(completed), "source": "AppStoreScreenshots UI tests; offline demo data"
        }, indent=2) + "\n")
        print(f"Saved {len(completed)} native screenshots to {output}")
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=15)
        test_run.unlink(missing_ok=True)
        run("xcrun", "simctl", "status_bar", args.device, "clear")
        # Retain staging after failure so a failed image/handshake can be inspected.
        if process is not None and process.returncode == 0:
            shutil.rmtree(staging)


if __name__ == "__main__":
    main()
