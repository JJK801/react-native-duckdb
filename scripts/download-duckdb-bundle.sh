#!/bin/bash
set -euo pipefail

# Fast path for the DuckDB native build: download a prebuilt, checksum-verified bundle of
# DuckDB's static libs (libduckdb_static.a + the extension and third_party .a's, built for a
# specific extension set) from the fork's GitHub Releases — so the consumer skips the ~8-min,
# ~2000-file DuckDB compile and just links these. The static extension-registration loader is
# baked into libduckdb_static.a, so the bundle is keyed by the exact extension set.
#
# Called by package/android/CMakeLists.txt only when RNDuckDB_prebuiltDuckdb=true. Prints the
# extracted lib dir as its final stdout line on success; exits non-zero on any miss (no prebuilt
# for this version/extension-set/ABI, offline, etc.) so CMake transparently falls back to the
# from-source build. A checksum MISMATCH exits non-zero too (CMake then builds from source).
#
# Usage: download-duckdb-bundle.sh android <arm64-v8a|x86_64> <extensions-csv>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$REPO_DIR/vendor"
REPO="JJK801/react-native-duckdb"

usage() { echo "Usage: $0 android <arm64-v8a|x86_64> <extensions-csv>"; exit 2; }
[ $# -lt 3 ] && usage
PLATFORM="$1"; ABI="$2"; EXTENSIONS="$3"
[ "$PLATFORM" != "android" ] && { echo "[duckdb-bundle] only 'android' supported" >&2; exit 2; }
case "$ABI" in arm64-v8a|x86_64) ;; *) echo "[duckdb-bundle] unsupported ABI '$ABI'" >&2; exit 2 ;; esac

# Extension-set token: normalize (split, drop empties, sort, comma-join) then sha256 first 12.
# build-duckdb-bundle.sh computes this identically so producer and consumer names match.
EXTSET_SORTED="$(printf '%s' "$EXTENSIONS" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | sed 's/[[:space:]]//g' | sort -u | paste -sd, -)"
HASH="$(printf '%s' "$EXTSET_SORTED" | shasum -a 256 | cut -c1-12)"

DUCKDB_VERSION="$(cat "$REPO_DIR/package/vendor/duckdb/DUCKDB_VERSION" 2>/dev/null || echo v1.4.4)"
TAG="duckdb-bundle-${DUCKDB_VERSION}"
FILE="duckdb-bundle-${DUCKDB_VERSION}-${HASH}-${ABI}.tar.gz"
OUT_DIR="$VENDOR_DIR/duckdb-bundle/android-$ABI"
LIB_DIR="$OUT_DIR/lib"
MARKER="$OUT_DIR/.bundle-version"
MARKER_VALUE="${DUCKDB_VERSION}-${HASH}"

# Already present for this exact (version x extension-set)? Reuse it.
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$MARKER_VALUE" ] && [ -f "$LIB_DIR/libduckdb_static.a" ]; then
  echo "[duckdb-bundle] $ABI already present (${MARKER_VALUE})" >&2
  echo "$LIB_DIR"
  exit 0
fi

BASE_URL="${DUCKDB_BUNDLE_BASE_URL:-https://github.com/${REPO}/releases/download/${TAG}}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "[duckdb-bundle] trying $BASE_URL/$FILE (extset=$EXTSET_SORTED)" >&2
curl -fL --retry 3 -o "$TMP/$FILE" "$BASE_URL/$FILE" >&2 || { echo "[duckdb-bundle] no prebuilt bundle — source build" >&2; exit 1; }

# Verify SHA256 (fail closed: a mismatch exits non-zero -> CMake builds from source).
if curl -fsSL "$BASE_URL/SHA256SUMS" -o "$TMP/SHA256SUMS" >&2; then
  EXPECTED="$(grep " ${FILE}\$" "$TMP/SHA256SUMS" | awk '{print $1}' | head -1)"
  ACTUAL="$(shasum -a 256 "$TMP/$FILE" | awk '{print $1}')"
  if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "[duckdb-bundle] checksum verify failed (expected '${EXPECTED:-none}', got $ACTUAL) — source build" >&2
    exit 1
  fi
else
  echo "[duckdb-bundle] could not fetch SHA256SUMS — source build" >&2
  exit 1
fi

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
tar -C "$OUT_DIR" -xzf "$TMP/$FILE" >&2
if [ ! -f "$LIB_DIR/libduckdb_static.a" ]; then
  echo "[duckdb-bundle] extracted bundle missing libduckdb_static.a — source build" >&2
  exit 1
fi

echo "$MARKER_VALUE" > "$MARKER"
echo "[duckdb-bundle] installed prebuilt $ABI bundle -> $LIB_DIR" >&2
# Final stdout line = the lib dir (consumed by CMake).
echo "$LIB_DIR"
