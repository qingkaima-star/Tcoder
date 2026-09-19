#!/bin/bash
# Build a double-clickable .app bundle for Apple Silicon from the SwiftPM executable.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="TcoderMonitor"
BUNDLE_NAME="Tcoder Monitor.app"
OUT_DIR="dist"
BIN_DIR=".build/arm64-apple-macosx/${CONFIG}"
APP_DIR="${OUT_DIR}/${BUNDLE_NAME}"

echo "==> swift build -c ${CONFIG} --arch arm64 (through the shared lock)"
./scripts/locked_build.sh build -c "${CONFIG}" --arch arm64

BIN=$(find "${BIN_DIR}" -maxdepth 1 -name "${APP_NAME}" -type f | head -1)
if [ -z "${BIN}" ]; then
  BIN=$(find ".build" -path "*/arm64*/*/${APP_NAME}" -type f -perm +111 | head -1)
fi
if [ -z "${BIN}" ]; then echo "!! built binary not found"; exit 1; fi
echo "==> binary: ${BIN}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - --timestamp=none "${APP_DIR}" >/dev/null 2>&1 || \
  codesign --force --sign - "${APP_DIR}/Contents/MacOS/${APP_NAME}"

echo "==> built: $(pwd)/${APP_DIR}"
du -sh "${APP_DIR}" | cut -f1 | xargs echo "    size:"
