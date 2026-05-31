#!/bin/bash
set -euo pipefail

# Produce a self-contained, installable npm tarball of the package — the same artifact a
# correct `npm publish` would create — for hosting on GitHub Releases instead of the npm
# registry. Consumers then depend on the tarball URL:
#   "react-native-duckdb": "https://github.com/JJK801/react-native-duckdb/releases/download/<tag>/react-native-duckdb-<ver>.tgz"
#
# IMPORTANT: this does NOT modify the source repo. The package keeps upstream's layout (lib in
# package/, build scripts and the duckdb submodule at the repo root). All adjustments happen on
# a STAGED COPY:
#   - copy scripts/ into the package so the subdir is self-contained;
#   - rewrite the android CMakeLists + podspec ../../scripts and ../../duckdb paths to be
#     package-relative (../scripts, ../duckdb) — only in the staged copy;
#   - wire a postinstall that fetches the DuckDB *source* at install time (it isn't bundled —
#     277MB — and the prebuilt deps/bundle are fetched later by CMake at build time).
#
# Usage: pack-github.sh   (run from anywhere; prints the produced .tgz path)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$REPO_DIR/package"

# 1. Build the JS bridge (lib/). Skip the typecheck target (needs a tsc path the workspace
#    doesn't expose); module + commonjs is what package.json main/module point at. Pin the
#    builder-bob version explicitly (-p) so npx doesn't pick up a different local copy.
if [ ! -d "$PKG_DIR/lib/module" ] || [ "${REBUILD_LIB:-0}" = "1" ]; then
  echo "=== building lib/ (builder-bob 0.40.18) ===" >&2
  ( cd "$PKG_DIR" && npx --yes -p react-native-builder-bob@0.40.18 bob build --target module --target commonjs ) >&2
else
  echo "=== lib/ already built — reusing (set REBUILD_LIB=1 to force) ===" >&2
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 2. `npm pack` to honor the package's `files` allow-list, then extract the staged "package/".
echo "=== npm pack (honors files allow-list) ===" >&2
TGZ="$(cd "$PKG_DIR" && npm pack --silent --pack-destination "$WORK")"
tar -xzf "$WORK/$TGZ" -C "$WORK"           # -> $WORK/package/
STAGE="$WORK/package"

# 3. Copy the build scripts into the package so the installed subdir is self-contained.
rm -rf "$STAGE/scripts"
cp -R "$REPO_DIR/scripts" "$STAGE/scripts"

# 4. Rewrite the reach-up paths in the STAGED build files only (source repo untouched).
#    package/android/CMakeLists.txt: ../../scripts -> ../scripts, ../../duckdb -> ../duckdb
sed -i.bak 's#\.\./\.\./scripts#../scripts#g; s#\.\./\.\./duckdb#../duckdb#g' "$STAGE/android/CMakeLists.txt" && rm -f "$STAGE/android/CMakeLists.txt.bak"
#    RNDuckDB.podspec (at package root): ../scripts -> scripts, ../duckdb -> duckdb
PODSPEC="$(ls "$STAGE"/*.podspec 2>/dev/null | head -1 || true)"
if [ -n "$PODSPEC" ]; then
  sed -i.bak 's#\.\./scripts#scripts#g; s#\.\./duckdb#duckdb#g' "$PODSPEC" && rm -f "$PODSPEC.bak"
fi

# 5. Wire the postinstall (fetch DuckDB source) into the staged package.json.
node -e '
  const fs = require("fs"), p = process.argv[1];
  const j = JSON.parse(fs.readFileSync(p, "utf8"));
  j.scripts = j.scripts || {};
  j.scripts.postinstall = "node scripts/fetch-duckdb-source.mjs";
  if (Array.isArray(j.files) && !j.files.includes("scripts")) j.files.push("scripts");
  fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
' "$STAGE/package.json"

# 6. Repack into a clean npm tarball (top-level dir must be "package").
VER="$(node -p "require('$STAGE/package.json').version")"
mkdir -p "$REPO_DIR/vendor"
OUT="$REPO_DIR/vendor/react-native-duckdb-${VER}.tgz"
( cd "$WORK" && COPYFILE_DISABLE=1 tar -czf "$OUT" package )
echo "=== Packed $OUT ($(du -h "$OUT" | cut -f1)) ===" >&2
echo "$OUT"
