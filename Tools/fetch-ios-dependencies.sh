#!/bin/bash
#
# Downloads the third-party runtime the iOS app embeds, verifies every archive against a pinned
# SHA-256 digest, and unpacks it into Vendor/ (which is git-ignored).
#
# iOS apps cannot launch external programs, so the iOS target cannot drive a separately
# installed yt-dlp the way the macOS app does. Instead it embeds a CPython interpreter and runs
# yt-dlp in-process. Nothing here is committed to the repository; run this script once before
# building the YTDLPGUI-iOS scheme, and again whenever the pins below change.
#
#   ./Tools/fetch-ios-dependencies.sh           fetch anything missing or out of date
#   ./Tools/fetch-ios-dependencies.sh --force   re-download and re-extract everything
#
# Updating a pin: change the version, URL and digest together. PyPI publishes the SHA-256 of
# every file in its JSON API (https://pypi.org/pypi/<name>/<version>/json); GitHub shows the
# digest of each release asset on the release page.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/Vendor"
CACHE_DIR="$VENDOR_DIR/.downloads"
PACKAGES_DIR="$VENDOR_DIR/python-packages"
STAMP_FILE="$VENDOR_DIR/.pins"

# --- Pins ------------------------------------------------------------------------------------

# CPython for iOS, built by the BeeWare project (PSF licence; bundled libraries carry their own).
PYTHON_SUPPORT_NAME="Python-3.14-iOS-support.b11.tar.gz"
PYTHON_SUPPORT_URL="https://github.com/beeware/Python-Apple-support/releases/download/3.14-b11/$PYTHON_SUPPORT_NAME"
PYTHON_SUPPORT_SHA256="b591f3301bd22a4f423c49c746cac9e55558b909fd14d6eb8327ccc62234ab7b"

# Pure-Python wheels, unpacked into Vendor/python-packages and copied into the app bundle.
# Format: "<wheel file name>|<url>|<sha256>"
WHEELS=(
    # yt-dlp itself (Unlicense).
    "yt_dlp-2026.8.19-py3-none-any.whl|https://files.pythonhosted.org/packages/69/b2/8cd1613f56eed7ceb64fbd4df3f1c01246bfb098e6f398228bafda22b80b/yt_dlp-2026.8.19-py3-none-any.whl|1d57897e94c6665a0a6f9bc54b34e584284e32c034ffab3a7df25d8f7b24eedf"
    # YouTube's JavaScript challenge solver scripts (Unlicense AND MIT AND ISC). The app runs
    # them in JavaScriptCore rather than an external JS runtime.
    "yt_dlp_ejs-0.8.0-py3-none-any.whl|https://files.pythonhosted.org/packages/e3/bd/520769863744b669440a924271a6159ddd82ad5ae26b4ac4d4b69e9f8d44/yt_dlp_ejs-0.8.0-py3-none-any.whl|79300e5fca7f937a1eeede11f0456862c1b41107ce1d726871e0207424f4bdb4"
    # Mozilla's CA bundle (MPL-2.0). The embedded OpenSSL cannot see the iOS trust store.
    "certifi-2026.7.22-py3-none-any.whl|https://files.pythonhosted.org/packages/0b/a7/71ac2cff56fec219ed242bb11b8efb69fcc4bec75db06fb7bfe35de520e6/certifi-2026.7.22-py3-none-any.whl|62f22742b58a1a33014a2b6b706588a8d7e2a88ae7bd1a6ebe8c992928483775"
)

# --- Helpers ---------------------------------------------------------------------------------

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--force]" >&2
    exit 64
fi

say() { printf '==> %s\n' "$*"; }

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Downloads $2 to $CACHE_DIR/$1 unless a copy with the expected digest ($3) is already there.
fetch() {
    local name="$1" url="$2" expected="$3"
    local destination="$CACHE_DIR/$name"

    if [[ -f "$destination" && $FORCE -eq 0 && "$(sha256_of "$destination")" == "$expected" ]]; then
        return 0
    fi

    say "Downloading $name"
    rm -f "$destination.partial"
    curl --fail --location --silent --show-error --retry 3 --output "$destination.partial" "$url"

    local actual
    actual="$(sha256_of "$destination.partial")"
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$destination.partial"
        echo "error: checksum mismatch for $name" >&2
        echo "  expected $expected" >&2
        echo "  got      $actual" >&2
        exit 1
    fi
    mv "$destination.partial" "$destination"
}

# The pins, as one string, so a changed pin forces re-extraction.
pin_fingerprint() {
    printf '%s\n' "$PYTHON_SUPPORT_SHA256" "${WHEELS[@]}" | shasum -a 256 | awk '{print $1}'
}

# --- Main ------------------------------------------------------------------------------------

mkdir -p "$CACHE_DIR"

fetch "$PYTHON_SUPPORT_NAME" "$PYTHON_SUPPORT_URL" "$PYTHON_SUPPORT_SHA256"
for entry in "${WHEELS[@]}"; do
    IFS='|' read -r name url digest <<< "$entry"
    fetch "$name" "$url" "$digest"
done

FINGERPRINT="$(pin_fingerprint)"
if [[ $FORCE -eq 0 && -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$FINGERPRINT" \
      && -d "$VENDOR_DIR/Python.xcframework" && -d "$PACKAGES_DIR" ]]; then
    say "Vendor/ is already up to date"
    exit 0
fi

say "Unpacking the Python runtime"
rm -rf "$VENDOR_DIR/Python.xcframework" "$VENDOR_DIR/python-support"
mkdir -p "$VENDOR_DIR/python-support"
tar -xzf "$CACHE_DIR/$PYTHON_SUPPORT_NAME" -C "$VENDOR_DIR/python-support"
mv "$VENDOR_DIR/python-support/Python.xcframework" "$VENDOR_DIR/Python.xcframework"

say "Unpacking Python packages"
rm -rf "$PACKAGES_DIR"
mkdir -p "$PACKAGES_DIR"
for entry in "${WHEELS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    # A wheel is a zip archive laid out exactly as site-packages expects.
    unzip -q -o "$CACHE_DIR/$name" -d "$PACKAGES_DIR"
done
# Byte-code caches are regenerated on device and only bloat the bundle.
find "$PACKAGES_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} +

echo "$FINGERPRINT" > "$STAMP_FILE"
say "Done. Vendor/ now contains:"
ls -1 "$VENDOR_DIR" | sed 's/^/    /'
