#!/bin/bash
# Builds the downloadable release into build/release/:
#   PSVR-Player-<version>.zip   the app
#   psvr-tools-<version>.zip    psvrplayer and psvrctl
# Build-folder paths are mapped to "." and debug maps stripped, so the binaries don't carry the
# builder's home folder. The script refuses to finish if any file still contains it.
# Usage: scripts/make-release.sh <version>, e.g. 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-release.sh <version>}"
OUT="build/release"
SCRATCH="build/release-build"
export SWIFT_BUILD_ARGS="--scratch-path $SCRATCH -Xswiftc -file-prefix-map -Xswiftc $PWD=."

rm -rf "$OUT" "$SCRATCH"
mkdir -p "$OUT/tools"

scripts/build-app.sh -
swift build -c release $SWIFT_BUILD_ARGS --product psvrplayer
swift build -c release $SWIFT_BUILD_ARGS --product psvrctl
BIN="$(swift build -c release $SWIFT_BUILD_ARGS --show-bin-path)"
for tool in psvrplayer psvrctl; do
    cp "$BIN/$tool" "$OUT/tools/"
    strip -S "$OUT/tools/$tool"
    codesign --force --sign - "$OUT/tools/$tool"
done
cp -R "build/PSVR Player.app" "$OUT/"

# Nothing from this machine may end up in a download.
if grep -rIl -a -e "$HOME" -e "$(whoami)" "$OUT" >/dev/null 2>&1; then
    echo "error: build output contains local paths or the user name:" >&2
    grep -rIl -a -e "$HOME" -e "$(whoami)" "$OUT" >&2
    exit 1
fi

ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$OUT/PSVR Player.app" "$OUT/PSVR-Player-$VERSION.zip"
ditto -c -k --norsrc --noextattr --noqtn --noacl "$OUT/tools" "$OUT/psvr-tools-$VERSION.zip"
shasum -a 256 "$OUT"/*.zip
