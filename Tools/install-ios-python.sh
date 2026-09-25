#!/bin/bash
#
# Xcode build phase for the YTDLPGUI-iOS target: installs the embedded Python runtime into the
# app bundle. Runs after resources are copied and before frameworks are embedded and signed.
#
#   <App>.app/python/lib/python3.x/   the standard library
#   <App>.app/app/ytdlpgui_host/      the engine host (PythonHost/ytdlpgui_host)
#   <App>.app/app_packages/           yt-dlp, yt-dlp-ejs and certifi (Vendor/python-packages)
#   <App>.app/Frameworks/*.framework  every binary extension module, repackaged as a framework
#                                     because iOS refuses to load a bare .so from an app bundle
#
# The repackaging and signing is done by the utilities that ship inside Python.xcframework.

set -euo pipefail

VENDOR_RELATIVE="Vendor"
XCFRAMEWORK_RELATIVE="$VENDOR_RELATIVE/Python.xcframework"

if [[ ! -d "$PROJECT_DIR/$XCFRAMEWORK_RELATIVE" || ! -d "$PROJECT_DIR/$VENDOR_RELATIVE/python-packages" ]]; then
    echo "error: The embedded Python runtime is missing. Run ./Tools/fetch-ios-dependencies.sh once, then build again."
    exit 1
fi

APP_DIR="$CODESIGNING_FOLDER_PATH"

echo "Installing the engine host"
mkdir -p "$APP_DIR/app"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' --exclude 'tests' \
    "$PROJECT_DIR/PythonHost/ytdlpgui_host/" "$APP_DIR/app/ytdlpgui_host/"

echo "Installing Python packages"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' \
    "$PROJECT_DIR/$VENDOR_RELATIVE/python-packages/" "$APP_DIR/app_packages/"

# shellcheck source=/dev/null
source "$PROJECT_DIR/$XCFRAMEWORK_RELATIVE/build/utils.sh"

install_stdlib "$XCFRAMEWORK_RELATIVE"
PYTHON_VERSION_DIR="$(ls -1 "$APP_DIR/python/lib" | grep -E '^python3\.[0-9]+$' | head -n 1)"
PYTHON_LIB_DIR="$APP_DIR/python/lib/$PYTHON_VERSION_DIR"

# Parts of the standard library that can never be used inside an iOS app. They are removed
# before the extension modules are repackaged, so no framework is built for them either.
for unused in test idlelib turtledemo tkinter ensurepip venv lib2to3 pydoc_data __phello__; do
    rm -rf "${PYTHON_LIB_DIR:?}/$unused"
done
find "$PYTHON_LIB_DIR/lib-dynload" \( -name '_test*.so' -o -name '_xxtest*.so' -o -name 'xx*.so' \
    -o -name '_ctypes_test*.so' \) -delete

echo "Repackaging extension modules as frameworks"
process_dylibs "$XCFRAMEWORK_RELATIVE" "python/lib/$PYTHON_VERSION_DIR/lib-dynload"
process_dylibs "$XCFRAMEWORK_RELATIVE" app
process_dylibs "$XCFRAMEWORK_RELATIVE" app_packages
