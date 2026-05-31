#!/bin/bash
set -euo pipefail

# Maintainer tool: build DuckDB's static libs from source for one ABI + extension set, strip
# them, and package a tarball for hosting on GitHub Releases. Consumers then download it via
# scripts/download-duckdb-bundle.sh (RNDuckDB_prebuiltDuckdb=true) and skip the DuckDB compile.
#
# Produces vendor/duckdb-bundle-<DUCKDB_VERSION>-<extset_hash>-<abi>.tar.gz (lib/*.a + MANIFEST)
# and refreshes vendor/SHA256SUMS.duckdb. The extension-set hash matches download-duckdb-bundle.sh.
#
# Usage: build-duckdb-bundle.sh android <arm64-v8a|x86_64> <extensions-csv>
#   e.g. build-duckdb-bundle.sh android x86_64 core_functions,parquet,spatial
#
# Env: ANDROID_NDK_ROOT (required). VCPKG_ROOT (optional, for the spatial deps build).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$REPO_DIR/vendor"

usage() { echo "Usage: $0 android <arm64-v8a|x86_64> <extensions-csv>"; exit 1; }
[ $# -lt 3 ] && usage
PLATFORM="$1"; ABI="$2"; EXTENSIONS="$3"
[ "$PLATFORM" != "android" ] && { echo "ERROR: only 'android' supported"; exit 1; }
case "$ABI" in arm64-v8a|x86_64) ;; *) echo "ERROR: unsupported ABI '$ABI'"; exit 1 ;; esac

# Same PATH-sanitization as build-spatial-deps.sh (a polluted PATH breaks ninja's lexer).
sanitize_path() {
  local clean="" p; local OLDIFS="$IFS"; IFS=":"
  for p in $PATH; do
    case "$p" in (*[!A-Za-z0-9_/.+-]*) continue ;; esac
    [ -d "$p" ] && clean="${clean:+$clean:}$p"
  done
  IFS="$OLDIFS"; export PATH="$clean"
}
sanitize_path
[ -z "${ANDROID_NDK_ROOT:-}" ] && { echo "ERROR: ANDROID_NDK_ROOT not set"; exit 1; }

# Need cmake + ninja + node. Prefer the Android SDK cmake if a standalone one isn't on PATH.
SDK_CMAKE_BIN="$(dirname "$ANDROID_NDK_ROOT")/../cmake/3.22.1/bin"
[ -d "$SDK_CMAKE_BIN" ] && export PATH="$SDK_CMAKE_BIN:$PATH"
command -v cmake >/dev/null || { echo "ERROR: cmake not found"; exit 1; }
NODE_BIN="$(command -v node || true)"
[ -z "$NODE_BIN" ] && { echo "ERROR: node not found (needed by configure-extensions.js)"; exit 1; }

# Extension-set token (must match download-duckdb-bundle.sh): normalize then sha256 first 12.
EXTSET_SORTED="$(printf '%s' "$EXTENSIONS" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | sed 's/[[:space:]]//g' | sort -u | paste -sd, -)"
HASH="$(printf '%s' "$EXTSET_SORTED" | shasum -a 256 | cut -c1-12)"
DUCKDB_VERSION="$(cat "$REPO_DIR/package/vendor/duckdb/DUCKDB_VERSION" 2>/dev/null || echo v1.4.4)"

echo "=== Building DuckDB bundle: $DUCKDB_VERSION / [$EXTSET_SORTED] (hash $HASH) / android-$ABI ===" >&2

# Generate the extension config DuckDB reads (duckdb/extension/extension_config_local.cmake).
"$NODE_BIN" "$SCRIPT_DIR/configure-extensions.js" --duckdb-path "$REPO_DIR/duckdb" --extensions "$EXTSET_SORTED" >&2

# Spatial needs its native deps (GEOS/PROJ/GDAL/...) to configure/link; fetch or build them.
DEP_ARGS=()
if printf '%s' ",$EXTSET_SORTED," | grep -q ",spatial,"; then
  SPATIAL_PREFIX="$(bash "$SCRIPT_DIR/download-spatial-deps.sh" android "$ABI" | tail -1)"
  DEP_ARGS=(
    -DCMAKE_PREFIX_PATH="$SPATIAL_PREFIX"
    -DCMAKE_FIND_ROOT_PATH="$SPATIAL_PREFIX"
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
    -DCMAKE_MAP_IMPORTED_CONFIG_DEBUG=Release
    -DCMAKE_MAP_IMPORTED_CONFIG_RELWITHDEBINFO=Release
    -DCMAKE_MAP_IMPORTED_CONFIG_MINSIZEREL=Release
    -DSPATIAL_USE_NETWORK=OFF
  )
fi

BUILD_DIR="$VENDOR_DIR/_duckdb-bundle-build/$ABI"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

cmake -S "$REPO_DIR/duckdb" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=20 \
  -DBUILD_SHELL=OFF -DBUILD_UNITTESTS=OFF -DBUILD_BENCHMARKS=OFF \
  -DENABLE_SANITIZER=OFF -DENABLE_UBSAN=OFF -DEXTENSION_STATIC_BUILD=OFF \
  -DBUILD_EXTENSIONS_ONLY=OFF -DDUCKDB_EXPLICIT_PLATFORM="android_$ABI" \
  "${DEP_ARGS[@]}" >&2

# Build duckdb_static + each extension's static lib (third_party libs are deps of duckdb_static).
TARGETS=(duckdb_static)
IFS=',' read -ra _exts <<< "$EXTSET_SORTED"
for e in "${_exts[@]}"; do TARGETS+=("${e}_extension"); done
cmake --build "$BUILD_DIR" -j"$JOBS" --target "${TARGETS[@]}" >&2

# Collect, strip, and package every .a the build produced.
STRIP_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64/bin/llvm-strip"
STAGE="$VENDOR_DIR/_duckdb-bundle-stage/$ABI"; rm -rf "$STAGE"; mkdir -p "$STAGE/lib"
find "$BUILD_DIR" -name "*.a" -exec cp {} "$STAGE/lib/" \;
[ -f "$STAGE/lib/libduckdb_static.a" ] || { echo "ERROR: libduckdb_static.a not produced"; exit 1; }
[ -x "$STRIP_BIN" ] && for a in "$STAGE/lib"/*.a; do "$STRIP_BIN" --strip-debug "$a" 2>/dev/null || true; done

cat > "$STAGE/MANIFEST" <<EOF
duckdb_version=$DUCKDB_VERSION
extensions=$EXTSET_SORTED
extset_hash=$HASH
abi=$ABI
api=24
stl=c++_shared
EOF

TARBALL="duckdb-bundle-${DUCKDB_VERSION}-${HASH}-${ABI}.tar.gz"
( cd "$STAGE" && COPYFILE_DISABLE=1 tar -czf "$VENDOR_DIR/$TARBALL" lib MANIFEST )
( cd "$VENDOR_DIR" && shasum -a 256 duckdb-bundle-*.tar.gz > SHA256SUMS.duckdb )
rm -rf "$BUILD_DIR" "$STAGE"   # reclaim disk (the build dir is large)
echo "=== Packaged $VENDOR_DIR/$TARBALL ($(du -h "$VENDOR_DIR/$TARBALL" | cut -f1)), libs: $(tar -tzf "$VENDOR_DIR/$TARBALL" | grep -c '\.a$') ===" >&2
echo "$VENDOR_DIR/$TARBALL"
