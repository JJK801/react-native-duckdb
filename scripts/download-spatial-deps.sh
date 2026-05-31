#!/bin/bash
set -euo pipefail

# Fast path for spatial's native deps: download a prebuilt, checksum-verified tarball from
# the fork's GitHub Releases and extract it where build-spatial-deps.sh would have installed
# it — instead of running the ~10-min vcpkg cross-compile. Falls back to the source build if
# no prebuilt is available (unpublished ABI, offline, checksum mismatch).
#
# Drop-in for build-spatial-deps.sh: same args (`android <abi>`), same install prefix, and
# the SAME final-stdout contract (the install tree, consumed by CMake as CMAKE_PREFIX_PATH).
#
# Usage: download-spatial-deps.sh android <arm64-v8a|x86_64>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$REPO_DIR/vendor"
REPO="JJK801/react-native-duckdb"
SPATIAL_COMMIT="f129b24b4ddd4d98cfc18f88be5a344a79040e7b"
MARKER_VALUE="$SPATIAL_COMMIT-api24-rel"   # must match build-spatial-deps.sh

usage() { echo "Usage: $0 android <arm64-v8a|x86_64>"; exit 1; }
[ $# -lt 2 ] && usage
PLATFORM="$1"; ABI="$2"
[ "$PLATFORM" != "android" ] && { echo "ERROR: only 'android' supported" >&2; exit 1; }
case "$ABI" in
  arm64-v8a) TRIPLET="arm64-android" ;;
  x86_64)    TRIPLET="x64-android" ;;
  *) echo "ERROR: unsupported ABI '$ABI'" >&2; exit 1 ;;
esac

OUT_DIR="$VENDOR_DIR/spatial/android-$ABI"
INSTALL_TREE="$OUT_DIR/$TRIPLET"
MARKER="$OUT_DIR/.spatial-deps-version"

fallback_to_source() {
  echo "[deps] $1 — falling back to source build" >&2
  exec "$SCRIPT_DIR/build-spatial-deps.sh" "$PLATFORM" "$ABI"
}

# Already present for this exact recipe? Reuse it (mirrors build-spatial-deps.sh's cache).
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$MARKER_VALUE" ] && [ -f "$INSTALL_TREE/lib/libgdal.a" ]; then
  echo "[deps] $ABI already present at $INSTALL_TREE" >&2
  echo "$INSTALL_TREE"
  exit 0
fi

DUCKDB_VERSION="$(cat "$REPO_DIR/package/vendor/duckdb/DUCKDB_VERSION" 2>/dev/null || echo v1.4.4)"
TAG="spatial-deps-${DUCKDB_VERSION}"
FILE="spatial-deps-${DUCKDB_VERSION}-${ABI}.tar.gz"
# Base URL of the hosted tarball + SHA256SUMS. Defaults to the fork's GitHub Releases;
# override SPATIAL_DEPS_BASE_URL to point at a mirror or a local server.
BASE_URL="${SPATIAL_DEPS_BASE_URL:-https://github.com/${REPO}/releases/download/${TAG}}"
URL="${BASE_URL}/${FILE}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "[deps] downloading $URL" >&2
curl -fL --retry 3 -o "$TMP/$FILE" "$URL" >&2 || fallback_to_source "no prebuilt for $ABI@$DUCKDB_VERSION"

# Verify SHA256 against the published SHA256SUMS (fail closed on mismatch — do NOT silently
# fall back to a source build, since a mismatch may indicate a corrupted/tampered asset).
if curl -fsSL "${BASE_URL}/SHA256SUMS" -o "$TMP/SHA256SUMS" >&2; then
  EXPECTED="$(grep " ${FILE}\$" "$TMP/SHA256SUMS" | awk '{print $1}' | head -1)"
  if [ -z "$EXPECTED" ]; then
    fallback_to_source "no SHA256SUMS entry for $FILE"
  fi
  ACTUAL="$(shasum -a 256 "$TMP/$FILE" | awk '{print $1}')"
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "[deps] CHECKSUM MISMATCH for $FILE (expected $EXPECTED, got $ACTUAL)" >&2
    exit 1
  fi
else
  fallback_to_source "could not fetch SHA256SUMS"
fi

# Extract into OUT_DIR so the tree lands exactly at $INSTALL_TREE ($OUT_DIR/$TRIPLET).
rm -rf "$INSTALL_TREE"
mkdir -p "$OUT_DIR"
tar -C "$OUT_DIR" -xzf "$TMP/$FILE" >&2
if [ ! -f "$INSTALL_TREE/lib/libgdal.a" ]; then
  echo "[deps] extracted tree missing libgdal.a at $INSTALL_TREE" >&2
  exit 1
fi

echo "$MARKER_VALUE" > "$MARKER"
echo "[deps] installed prebuilt $ABI deps -> $INSTALL_TREE" >&2
# Final stdout line = the install tree (consumed by CMake as CMAKE_PREFIX_PATH).
echo "$INSTALL_TREE"
