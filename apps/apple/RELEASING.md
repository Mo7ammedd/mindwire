# Mac releases

Every `vX.Y.Z` release builds the shared Apple app for Mac Catalyst on Xcode 26.5,
with both `arm64` and `x86_64` slices and the matching local Go runtime. XcodeGen
uses `project.yml` and the committed `Package.resolved`. iOS App Store builds
continue to use their own marketing version and build number.

The Mac bundle uses the release version and Actions run number. The release
includes `Mindwire.dmg` and `Mindwire.dmg.sha256`, and adds the installer to the
release's `checksums.txt`. The website and phone setup link to:

https://github.com/oblien/mindwire/releases/latest/download/Mindwire.dmg

The release gate, Mac signing and Apple notarization must all succeed before the
GitHub release is published. No unsigned fallback is published. The npm-only
manual workflow remains available independently.

## GitHub Actions credentials

Use the same Apple account and Developer ID certificate as OpenShip:

- `APPLE_IDENTITY`: full Developer ID Application certificate name.
- `APPLE_CERTIFICATE_P12_BASE64`: base64-encoded PKCS#12 containing that certificate and private key.
- `APPLE_CERTIFICATE_PASSWORD`: PKCS#12 password.
- `APPLE_ID`: Apple developer account email.
- `APPLE_PASSWORD`: app-specific password for notarization.
- `APPLE_TEAM_ID`: `5Q877873WD`.
- `APPLE_PROVISIONING_PROFILES_BASE64`: base64-encoded flat ZIP of the Developer ID
  `.provisionprofile` files for the app and notification extension. These preserve
  CloudKit, push and App Group entitlements. Development or App Store profiles
  cannot replace Developer ID profiles.

Certificate import uses an ephemeral keychain; the keychain is deleted when the
build job finishes. Credentials never enter source, artifacts or the DMG.

## Build locally

With Xcode 26.5, XcodeGen, Go, the Developer ID certificate and a signed-in Xcode
developer account:

```sh
python3 scripts/release-macos.py build --version 0.1.59 --build-number 1 \
  --output /tmp/mindwire-mac-release
```

Local signing allows Xcode to obtain Developer ID provisioning profiles. CI uses
the saved profiles and manually selects the imported signing identity. The export
sets CloudKit's production environment. Code signatures and architecture slices
are verified before the disk image is created.

For compilation without distribution credentials, add `--archive-only`. This
produces a universal archive, not a distributable installer. An existing archive
can be exported with the `export` command and the same `--output` directory.

## Resume notarization

Build, submit and finish run as separate jobs. The signed DMG and Apple receipt
are retained for 14 days. The receipt binds the submission to its installer hash,
source commit and workflow run. Apple acceptance, stapling and Gatekeeper
assessment are required before the final artifact reaches the publisher.

If Apple is slow or temporarily unavailable, re-run failed jobs on the same
release run. The finish job resumes the saved submission. A rejected submission
blocks publication. Fix code in a new version after anything from a release has
already been published; never move an existing published tag.
