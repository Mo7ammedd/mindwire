#!/bin/sh
set -eu
# The phone remains a client; only the desktop embeds the native computer runtime.
if [ "$PLATFORM_NAME" != "macosx" ]; then exit 0; fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v go >/dev/null 2>&1; then
    echo "error: Install Go to build Mindwire's bundled Mac runtime." >&2
    exit 1
fi
runtime_source="$SRCROOT/../../packages/daemon"
runtime_build="$DERIVED_FILE_DIR/local-runtime"
runtime_destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$runtime_build" "$runtime_destination"
cd "$runtime_source"
runtime_parts=""
for runtime_arch in $ARCHS; do
    case "$runtime_arch" in
        arm64) runtime_goarch=arm64 ;;
        x86_64) runtime_goarch=amd64 ;;
        *) echo "error: Unsupported Mac architecture: $runtime_arch" >&2; exit 1 ;;
    esac
    runtime_binary="$runtime_build/mindwired-$runtime_arch"
    GOTOOLCHAIN=auto CGO_ENABLED=0 GOOS=darwin GOARCH="$runtime_goarch" go build -trimpath -o "$runtime_binary" ./cmd/daemon
    runtime_parts="$runtime_parts $runtime_arch"
done
# Use explicit arguments; derived-data paths can contain spaces.
set --
for runtime_arch in $runtime_parts; do set -- "$@" "$runtime_build/mindwired-$runtime_arch"; done
if [ "$#" -eq 1 ]; then
    cp "$1" "$runtime_destination/mindwired"
else
    /usr/bin/lipo -create "$@" -output "$runtime_destination/mindwired"
fi
chmod 755 "$runtime_destination/mindwired"
if [ "$CODE_SIGNING_ALLOWED" != "NO" ]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$runtime_destination/mindwired"
fi
