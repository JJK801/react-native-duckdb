# Overlay triplet: same as vcpkg's stock x64-android but pinned to API 24 to match the
# library's minSdkVersion (gradle.properties RNDuckDB_minSdkVersion=24). See the arm64
# triplet for why API 24 (avoids GDAL referencing API 28 Bionic symbols posix_spawn*/getrandom).
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION 24)
set(VCPKG_MAKE_BUILD_TRIPLET "--host=x86_64-linux-android")
set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DANDROID_ABI=x86_64)
