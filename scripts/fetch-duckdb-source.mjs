#!/usr/bin/env node
// Package postinstall: ensure the DuckDB source is present at <package>/duckdb. The native
// build needs its headers (and CMakeLists / extension config). In the monorepo it's a git
// submodule (already there, so this is a no-op); when the package is installed from the
// GitHub-hosted tarball, duckdb/ is absent, so fetch the pinned source archive once.
//
// The prebuilt spatial deps and the prebuilt DuckDB bundle are still fetched later, at build
// time, by CMake (scripts/download-*.sh) — this only provides the DuckDB *source tree*.
import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { execFileSync } from 'node:child_process'

const PKG_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const DUCKDB_DIR = join(PKG_ROOT, 'duckdb')
const COMMIT = '6ddac802ffa9bcfbcc3f5f0d71de5dff9b0bc250' // DuckDB v1.4.4 (matches the submodule)
const URL = `https://github.com/duckdb/duckdb/archive/${COMMIT}.tar.gz`

if (existsSync(join(DUCKDB_DIR, 'CMakeLists.txt'))) {
  process.exit(0) // already present (monorepo submodule or a previous install)
}

try {
  process.stdout.write(`[react-native-duckdb] fetching DuckDB source @ ${COMMIT.slice(0, 12)} ...\n`)
  // curl + tar are available on macOS/Linux dev machines (the platforms RN native builds run on).
  execFileSync(
    'bash',
    ['-c', `set -euo pipefail; mkdir -p "${DUCKDB_DIR}"; curl -fL --retry 3 "${URL}" | tar -xz -C "${DUCKDB_DIR}" --strip-components=1`],
    { stdio: 'inherit' }
  )
  process.stdout.write('[react-native-duckdb] DuckDB source ready at ./duckdb\n')
} catch (e) {
  process.stderr.write(`[react-native-duckdb] ERROR: failed to fetch DuckDB source: ${e.message}\n`)
  process.stderr.write('  The native build needs it — ensure curl, tar and network access are available.\n')
  process.exit(1)
}
