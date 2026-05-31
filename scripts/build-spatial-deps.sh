#!/bin/bash
set -euo pipefail

# Cross-compile DuckDB-spatial's native dependencies (GEOS, PROJ, GDAL, sqlite3,
# libgeotiff, tiff, json-c, expat, openssl, zlib) for Android using vcpkg, so the
# spatial extension can be statically linked into the RNDuckDB .so.
#
# Usage: build-spatial-deps.sh android <abi>
#   abi: arm64-v8a | x86_64   (64-bit only — spatial's deps don't target 32-bit Android,
#        and spatial's own vcpkg.json guards curl/network with !android)
#
# Output: vendor/spatial/android-<abi>/<triplet>/  — a vcpkg install tree. Pass that
#         directory as CMAKE_PREFIX_PATH so find_package(GDAL/PROJ/GEOS/EXPAT/...) resolves.
#         The resolved tree path is echoed as the final stdout line.
#
# Env:
#   ANDROID_NDK_ROOT  (required) path to the Android NDK (vcpkg's android triplet reads it)
#   VCPKG_ROOT        (optional) existing vcpkg checkout; bootstrapped into vendor/vcpkg if unset

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$REPO_DIR/vendor"

# Pinned to match DuckDB 1.4.4's spatial (duckdb/.github/config/extensions/spatial.cmake).
SPATIAL_GIT_URL="https://github.com/duckdb/duckdb-spatial"
SPATIAL_COMMIT="f129b24b4ddd4d98cfc18f88be5a344a79040e7b"
# vcpkg builtin-baseline declared in spatial's vcpkg.json — must be reachable in vcpkg's git history.
VCPKG_BASELINE="ce613c41372b23b1f51333815feb3edd87ef8a8b"

usage() { echo "Usage: $0 android <arm64-v8a|x86_64>"; exit 1; }
[ $# -lt 2 ] && usage
PLATFORM="$1"; ABI="$2"
[ "$PLATFORM" != "android" ] && { echo "ERROR: only 'android' is supported (got '$PLATFORM')"; exit 1; }

case "$ABI" in
  arm64-v8a) TRIPLET="arm64-android" ;;
  x86_64)    TRIPLET="x64-android" ;;
  *) echo "ERROR: unsupported ABI '$ABI' (need arm64-v8a or x86_64)"; exit 1 ;;
esac

OUT_DIR="$VENDOR_DIR/spatial/android-$ABI"
INSTALL_TREE="$OUT_DIR/$TRIPLET"
MARKER="$OUT_DIR/.spatial-deps-version"
# Cache key: spatial commit + a recipe tag. Bump the tag whenever the build recipe changes
# (e.g. the overlay triplet's API level) so a stale tree is rebuilt rather than reused.
MARKER_VALUE="$SPATIAL_COMMIT-api24-rel"

# Cache: skip if already installed for this exact spatial commit + recipe.
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$MARKER_VALUE" ] && [ -f "$INSTALL_TREE/lib/libgdal.a" ]; then
  echo "--- spatial deps for android-$ABI: cached (${MARKER_VALUE:0:12}…/api24), skipping ---" >&2
  echo "$INSTALL_TREE"
  exit 0
fi

# The build environment's PATH may contain non-directory entries (observed on this
# machine: yarn help text leaking into PATH). CMake bakes PATH into the generated
# build.ninja, and stray characters like '#' break ninja's lexer ("lexing error"),
# failing the GDAL build. Keep only well-formed existing directory entries.
sanitize_path() {
  local clean="" p
  local OLDIFS="$IFS"; IFS=":"
  for p in $PATH; do
    case "$p" in (*[!A-Za-z0-9_/.+-]*) continue ;; esac
    [ -d "$p" ] && clean="${clean:+$clean:}$p"
  done
  IFS="$OLDIFS"
  export PATH="$clean"
}
sanitize_path

[ -z "${ANDROID_NDK_ROOT:-}" ] && { echo "ERROR: ANDROID_NDK_ROOT not set"; exit 1; }
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

# vcpkg: use an existing checkout, else bootstrap a private copy under vendor/.
if [ -z "${VCPKG_ROOT:-}" ]; then
  VCPKG_ROOT="$VENDOR_DIR/vcpkg"
  if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
    echo "--- Bootstrapping vcpkg into $VCPKG_ROOT ---" >&2
    [ -d "$VCPKG_ROOT/.git" ] || git clone https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT" --depth 1
    "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
  fi
fi
export VCPKG_ROOT

# Manifest mode reads version constraints from the builtin-baseline commit; make it available.
git -C "$VCPKG_ROOT" cat-file -e "${VCPKG_BASELINE}^{commit}" 2>/dev/null \
  || git -C "$VCPKG_ROOT" fetch --depth 1 origin "$VCPKG_BASELINE"

# Fetch the spatial source at the pinned commit (provides vcpkg.json + trimmed overlay ports).
SPATIAL_SRC="$VENDOR_DIR/spatial-src"
if [ ! -f "$SPATIAL_SRC/.commit" ] || [ "$(cat "$SPATIAL_SRC/.commit")" != "$SPATIAL_COMMIT" ]; then
  echo "--- Fetching duckdb-spatial @ ${SPATIAL_COMMIT:0:12} ---" >&2
  rm -rf "$SPATIAL_SRC"
  git init -q "$SPATIAL_SRC"
  git -C "$SPATIAL_SRC" remote add origin "$SPATIAL_GIT_URL"
  git -C "$SPATIAL_SRC" fetch -q --depth 1 origin "$SPATIAL_COMMIT"
  git -C "$SPATIAL_SRC" checkout -q FETCH_HEAD
  echo "$SPATIAL_COMMIT" > "$SPATIAL_SRC/.commit"
fi

echo "=== Building spatial native deps for android-$ABI (vcpkg triplet $TRIPLET) ===" >&2
mkdir -p "$OUT_DIR"
# Run vcpkg in manifest mode from the spatial source dir so it picks up spatial's
# vcpkg.json, its ./vcpkg_ports overlay (trimmed GDAL/PROJ/sqlite3), and builtin-baseline.
( cd "$SPATIAL_SRC" && "$VCPKG_ROOT/vcpkg" install \
    --triplet "$TRIPLET" \
    --overlay-triplets="$SCRIPT_DIR/vcpkg-triplets" \
    --x-install-root="$OUT_DIR" \
    --clean-after-build ) >&2

echo "$MARKER_VALUE" > "$MARKER"
echo "=== Done: spatial deps installed to $INSTALL_TREE ===" >&2
# Final stdout line = the install tree (consumed by CMake as CMAKE_PREFIX_PATH).
echo "$INSTALL_TREE"
