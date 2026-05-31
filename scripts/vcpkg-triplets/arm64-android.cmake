# Overlay triplet: same as vcpkg's stock arm64-android but pinned to API 24 to match the
# library's minSdkVersion (gradle.properties RNDuckDB_minSdkVersion=24). The stock triplet
# uses API 28, which makes GDAL reference Bionic symbols added in API 28 (posix_spawn*,
# getrandom) — those would fail to resolve when linked into / loaded by an API 24 .so.
# Building at API 24 makes GDAL's CMake feature checks fall back to API 24-safe code paths.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION 24)
set(VCPKG_MAKE_BUILD_TRIPLET "--host=aarch64-linux-android")
set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DANDROID_ABI=arm64-v8a)
# Release only — mobile links the Release deps (DuckDB is always built Release here), and
# this halves build time, omits the huge debug .a's, and keeps the install tree's CMake
# config files free of debug import-checks that would fail once debug libs are absent.
set(VCPKG_BUILD_TYPE release)
