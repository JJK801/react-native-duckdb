cmake_minimum_required(VERSION 3.13)
project(RNDuckDB)

set(CMAKE_VERBOSE_MAKEFILE ON)
set(CMAKE_CXX_STANDARD 20)

# Path to DuckDB source (submodule at react-native-duckdb/duckdb/)
set(DUCKDB_SOURCE_DIR "${CMAKE_SOURCE_DIR}/../../duckdb")

# Run extension configuration script to generate extension_config_local.cmake.
# APP_ROOT_DIR is passed from build.gradle (rootProject.projectDir.parentFile).
# DUCKDB_EXTENSIONS is set from gradle.properties when Expo config plugin is used.
find_program(NODE_EXECUTABLE node REQUIRED)

set(CONFIGURE_ARGS
  ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/../../scripts/configure-extensions.js
  --duckdb-path ${DUCKDB_SOURCE_DIR}
  --app-root ${APP_ROOT_DIR}
)

# When extensions are provided via gradle.properties (Expo managed workflow),
# pass them directly — this overrides package.json discovery.
if(NOT "${DUCKDB_EXTENSIONS}" STREQUAL "")
  list(APPEND CONFIGURE_ARGS --extensions "${DUCKDB_EXTENSIONS}")
endif()

execute_process(
  COMMAND ${CONFIGURE_ARGS}
  RESULT_VARIABLE CONFIGURE_RESULT
)
if(NOT CONFIGURE_RESULT EQUAL 0)
  message(FATAL_ERROR "react-native-duckdb: Extension configuration failed (exit ${CONFIGURE_RESULT})")
endif()

# DuckDB build options — disable everything we don't need on mobile
set(BUILD_SHELL OFF CACHE BOOL "" FORCE)
set(BUILD_UNITTESTS OFF CACHE BOOL "" FORCE)
set(BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(ENABLE_SANITIZER OFF CACHE BOOL "" FORCE)
set(ENABLE_UBSAN OFF CACHE BOOL "" FORCE)
set(EXTENSION_STATIC_BUILD OFF CACHE BOOL "" FORCE)
set(BUILD_EXTENSIONS_ONLY OFF CACHE BOOL "" FORCE)
set(DUCKDB_EXPLICIT_PLATFORM "android_${ANDROID_ABI}" CACHE STRING "" FORCE)

# Check if httpfs is in the extension config (needs OpenSSL + libcurl)
set(EXT_CONFIG_PATH "${DUCKDB_SOURCE_DIR}/extension/extension_config_local.cmake")
if(EXISTS "${EXT_CONFIG_PATH}")
  file(READ "${EXT_CONFIG_PATH}" _ext_config_content)
  if(_ext_config_content MATCHES "httpfs")
    # httpfs requires OpenSSL + libcurl which only support 64-bit ABIs.
    # 32-bit Android devices are effectively extinct (Google required 64-bit since 2019).
    if(ANDROID_ABI STREQUAL "armeabi-v7a" OR ANDROID_ABI STREQUAL "x86")
      message(WARNING "react-native-duckdb: httpfs skipped for ${ANDROID_ABI} (32-bit not supported). httpfs requires 64-bit ABIs (arm64-v8a, x86_64).")
      # Strip httpfs from extension config so DuckDB doesn't try to build it.
      # Safe because configure-extensions.js regenerates this file each CMake invocation.
      file(STRINGS "${EXT_CONFIG_PATH}" _ext_lines)
      file(WRITE "${EXT_CONFIG_PATH}" "")
      foreach(_line IN LISTS _ext_lines)
        if(NOT _line MATCHES "duckdb_extension_load\\(httpfs")
          file(APPEND "${EXT_CONFIG_PATH}" "${_line}\n")
        endif()
      endforeach()
    else()
      message(STATUS "react-native-duckdb: httpfs detected, building OpenSSL + libcurl for ${ANDROID_ABI}")

      # Pass NDK path from build.gradle so the cross-compilation script can find the toolchain
      if(ANDROID_NDK_FOR_HTTPFS)
        set(ENV{ANDROID_NDK_ROOT} "${ANDROID_NDK_FOR_HTTPFS}")
      endif()

      set(VENDOR_DIR "${CMAKE_SOURCE_DIR}/../../vendor")
      execute_process(
        COMMAND bash "${CMAKE_SOURCE_DIR}/../../scripts/build-openssl-curl.sh" android "${ANDROID_ABI}"
        RESULT_VARIABLE _httpfs_deps_result
      )
      if(NOT _httpfs_deps_result EQUAL 0)
        message(FATAL_ERROR "react-native-duckdb: Failed to build OpenSSL/curl for httpfs (${ANDROID_ABI})")
      endif()

      # CMake's FindOpenSSL and FindCURL modules don't reliably locate libs during
      # NDK cross-compilation (sysroot search paths don't include our vendor dir).
      # Spell out every path so DuckDB's httpfs extension links correctly.
      set(OPENSSL_ROOT_DIR "${VENDOR_DIR}/openssl/android-${ANDROID_ABI}" CACHE PATH "" FORCE)
      set(OPENSSL_INCLUDE_DIR "${VENDOR_DIR}/openssl/android-${ANDROID_ABI}/include" CACHE PATH "" FORCE)
      set(OPENSSL_SSL_LIBRARY "${VENDOR_DIR}/openssl/android-${ANDROID_ABI}/lib/libssl.a" CACHE FILEPATH "" FORCE)
      set(OPENSSL_CRYPTO_LIBRARY "${VENDOR_DIR}/openssl/android-${ANDROID_ABI}/lib/libcrypto.a" CACHE FILEPATH "" FORCE)
      set(OPENSSL_USE_STATIC_LIBS TRUE CACHE BOOL "" FORCE)
      set(CURL_ROOT "${VENDOR_DIR}/curl/android-${ANDROID_ABI}" CACHE PATH "" FORCE)
      set(CURL_INCLUDE_DIR "${VENDOR_DIR}/curl/android-${ANDROID_ABI}/include" CACHE PATH "" FORCE)
      set(CURL_LIBRARY "${VENDOR_DIR}/curl/android-${ANDROID_ABI}/lib/libcurl.a" CACHE FILEPATH "" FORCE)
      set(_HTTPFS_ENABLED TRUE)

      # libcurl depends on system zlib — ensure both DuckDB and our lib can link it.
      # Set this globally so DuckDB's own shared lib target can also find zlib.
      find_library(ZLIB_LIB z)
      set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -lz")
    endif()
  endif()
endif()

# Check if VSS extension is in the config — needs aligned_alloc workaround on Android.
# Android Bionic's aligned_alloc requires API level 28+, but we target API 24.
# The usearch library (bundled in duckdb-vss) calls aligned_alloc directly.
# We provide an inline wrapper using posix_memalign (available since API 16).
if(EXISTS "${EXT_CONFIG_PATH}")
  file(READ "${EXT_CONFIG_PATH}" _ext_config_content_vss)
  if(_ext_config_content_vss MATCHES "vss")
    message(STATUS "react-native-duckdb: VSS detected, adding aligned_alloc workaround for Android API ${ANDROID_NATIVE_API_LEVEL}")
    set(_VSS_ENABLED TRUE)
  endif()
endif()

# Check if spatial is in the config — it needs GEOS/PROJ/GDAL (+ sqlite3/tiff/geotiff/
# json-c/expat/openssl/zlib), which we cross-compile with vcpkg via
# scripts/build-spatial-deps.sh. Mirrors the httpfs precedent (build deps, inject paths).
if(EXISTS "${EXT_CONFIG_PATH}")
  file(READ "${EXT_CONFIG_PATH}" _ext_config_content_spatial)
  if(_ext_config_content_spatial MATCHES "spatial")
    # spatial's native deps target 64-bit ABIs only (its vcpkg.json guards curl/network
    # with !android, and 32-bit Android is effectively extinct since Google's 2019 mandate).
    if(ANDROID_ABI STREQUAL "armeabi-v7a" OR ANDROID_ABI STREQUAL "x86")
      message(WARNING "react-native-duckdb: spatial skipped for ${ANDROID_ABI} (64-bit only: arm64-v8a, x86_64). Stripping from extension config.")
      # Strip spatial so DuckDB doesn't try to build it. Safe: configure-extensions.js
      # regenerates this file on each CMake invocation (same pattern as httpfs above).
      file(STRINGS "${EXT_CONFIG_PATH}" _ext_lines)
      file(WRITE "${EXT_CONFIG_PATH}" "")
      foreach(_line IN LISTS _ext_lines)
        if(NOT _line MATCHES "duckdb_extension_load\\(spatial")
          file(APPEND "${EXT_CONFIG_PATH}" "${_line}\n")
        endif()
      endforeach()
    else()
      message(STATUS "react-native-duckdb: spatial detected, cross-compiling native deps (GEOS/PROJ/GDAL) for ${ANDROID_ABI}")

      # Reuse the NDK path plumbed for httpfs (build.gradle sets ANDROID_NDK_FOR_HTTPFS).
      if(ANDROID_NDK_FOR_HTTPFS)
        set(ENV{ANDROID_NDK_ROOT} "${ANDROID_NDK_FOR_HTTPFS}")
      endif()

      execute_process(
        COMMAND bash "${CMAKE_SOURCE_DIR}/../../scripts/build-spatial-deps.sh" android "${ANDROID_ABI}"
        RESULT_VARIABLE _spatial_deps_result
        OUTPUT_VARIABLE _SPATIAL_PREFIX
        OUTPUT_STRIP_TRAILING_WHITESPACE
      )
      if(NOT _spatial_deps_result EQUAL 0)
        message(FATAL_ERROR "react-native-duckdb: Failed to cross-compile spatial native deps for ${ANDROID_ABI}")
      endif()

      # The script prints the vcpkg install tree as its final stdout line. Adding it to
      # CMAKE_PREFIX_PATH lets spatial's find_package(GDAL/PROJ/GEOS/EXPAT/sqlite3/...)
      # resolve. It propagates into the extension because DuckDB adds out-of-tree
      # extensions via add_subdirectory in this same configure scope.
      if(NOT EXISTS "${_SPATIAL_PREFIX}/lib/libgdal.a")
        message(FATAL_ERROR "react-native-duckdb: spatial deps tree missing libgdal.a at '${_SPATIAL_PREFIX}'")
      endif()
      list(APPEND CMAKE_PREFIX_PATH "${_SPATIAL_PREFIX}")
      # The NDK toolchain sets CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY, which makes
      # find_package ignore CMAKE_PREFIX_PATH and only search the NDK sysroot. Allow host
      # paths so spatial's find_package(GDAL/PROJ/GEOS/... CONFIG) resolves our vcpkg tree.
      # (Library mode stays ONLY — vcpkg's *Config.cmake files reference absolute .a paths.)
      set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
      list(APPEND CMAKE_FIND_ROOT_PATH "${_SPATIAL_PREFIX}")
      message(STATUS "react-native-duckdb: spatial deps at ${_SPATIAL_PREFIX}")

      # The prebuilt deps ship Release variants only (the Debug .a's are huge and unused —
      # DuckDB is always built Release here via the wrapper below). Map every build config
      # to the Release imported target so find_package(GDAL/PROJ/... CONFIG) resolves even
      # in a Debug app build (e.g. the example app), instead of selecting an absent Debug lib.
      set(CMAKE_MAP_IMPORTED_CONFIG_DEBUG "Release;")
      set(CMAKE_MAP_IMPORTED_CONFIG_RELWITHDEBINFO "Release;")
      set(CMAKE_MAP_IMPORTED_CONFIG_MINSIZEREL "Release;")
      set(CMAKE_MAP_IMPORTED_CONFIG_ "Release;")

      # spatial defaults SPATIAL_USE_NETWORK=ON and only auto-disables it for Emscripten,
      # so on Android it would call find_package(CURL REQUIRED). We deliberately don't build
      # curl (spatial's vcpkg.json guards it with !android), and ST_* geometry functions
      # don't need network drivers — so force it off before the extension is configured.
      set(SPATIAL_USE_NETWORK OFF CACHE BOOL "react-native-duckdb: spatial network drivers off on mobile" FORCE)

      # Fold the spatial native deps (GEOS/PROJ/GDAL/sqlite3/tiff/geotiff/json-c/expat/
      # openssl/z) into the final .so, wrapped in a --start-group/--end-group so lld (which
      # is single-pass over archives) resolves their interdependencies (libtiff->libjpeg,
      # gdal->proj/geos/tiff, ...) regardless of order.
      #
      # This group MUST come at the very end of the link line: the spatial extension and
      # GDAL's find_package imported targets pull libtiff/libgdal/... in ahead of it, and
      # those archives reference symbols (jpeg/lzma/z) whose providing archives must follow.
      # CMake offers no way to place items after transitive imported-target libs via
      # target_link_libraries (and it de-duplicates repeated archives), so we append the
      # group through CMAKE_CXX_STANDARD_LIBRARIES, which the link rule emits dead last.
      file(GLOB _SPATIAL_LIBS "${_SPATIAL_PREFIX}/lib/*.a")
      string(REPLACE ";" "," _spatial_libs_csv "${_SPATIAL_LIBS}")
      set(CMAKE_CXX_STANDARD_LIBRARIES
        "${CMAKE_CXX_STANDARD_LIBRARIES} -Wl,--start-group,${_spatial_libs_csv},--end-group")
      set(_SPATIAL_ENABLED TRUE)
    endif()
  endif()
endif()

# Always build DuckDB with Release optimizations (-O3 -DNDEBUG), even for debug
# app builds. This matches the iOS behavior where DuckDB.xcframework is always
# pre-built with -DCMAKE_BUILD_TYPE=Release. Without this, AGP maps debug builds
# to CMAKE_BUILD_TYPE=Debug which compiles DuckDB at -O0 — causing ~30x slowdowns.
#
# We use a wrapper subdirectory to scope add_compile_options to DuckDB only.
# The wrapper's add_compile_options(-O3 -DNDEBUG) applies to DuckDB and its
# children but NOT to our RNDuckDB target (which is defined in this file).
add_subdirectory(duckdb-release-wrapper ${CMAKE_CURRENT_BINARY_DIR}/duckdb EXCLUDE_FROM_ALL)

# Our library source files
file(GLOB_RECURSE cpp_files RELATIVE ${CMAKE_SOURCE_DIR}
  "../cpp/**.cpp"
  "cpp-adapter.cpp"
)

add_library(${CMAKE_PROJECT_NAME} SHARED ${cpp_files})

include(${CMAKE_SOURCE_DIR}/../nitrogen/generated/android/RNDuckDB+autolinking.cmake)

# Include paths: DuckDB source headers + our C++ code
target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE
  ${DUCKDB_SOURCE_DIR}/src/include
  ${CMAKE_SOURCE_DIR}/../cpp
)

set_target_properties(
  ${CMAKE_PROJECT_NAME} PROPERTIES
  CXX_STANDARD ${CMAKE_CXX_STANDARD}
  CXX_EXTENSIONS OFF
  POSITION_INDEPENDENT_CODE ON
)

find_package(ReactAndroid REQUIRED CONFIG)
find_package(fbjni REQUIRED CONFIG)
find_library(LOG_LIB log)

# Link DuckDB static library + extension libraries (same pattern as DuckDB shell)
target_link_libraries(
  ${CMAKE_PROJECT_NAME}
  duckdb_static
  ${LOG_LIB}
  android
  fbjni::fbjni
  ReactAndroid::jsi
)
link_extension_libraries(${CMAKE_PROJECT_NAME} PRIVATE)

# Link vendor OpenSSL + libcurl static libs into our .so when httpfs is enabled.
# DuckDB's httpfs extension references OpenSSL/curl symbols but doesn't link them
# itself — the consuming library (us) must provide them at final link time.
if(_HTTPFS_ENABLED)
  find_library(ZLIB_LIB z)
  target_link_libraries(${CMAKE_PROJECT_NAME}
    ${OPENSSL_SSL_LIBRARY}
    ${OPENSSL_CRYPTO_LIBRARY}
    ${CURL_LIBRARY}
    ${ZLIB_LIB}
  )
endif()

# NOTE: spatial's native deps are linked via CMAKE_CXX_STANDARD_LIBRARIES (set in the
# spatial-detection block above) so the --start-group/--end-group lands at the very end of
# the link line — after the extension's transitive imported-target archives. See that block.

if (REACTNATIVE_MERGED_SO OR ReactAndroid_VERSION_MINOR GREATER_EQUAL 76)
  target_link_libraries(
    ${CMAKE_PROJECT_NAME}
    ReactAndroid::reactnative
  )
else()
  target_link_libraries(
    ${CMAKE_PROJECT_NAME}
    ReactAndroid::turbomodulejsijni
    ReactAndroid::react_nativemodule_core
  )
endif()

target_compile_options(
  ${CMAKE_PROJECT_NAME}
  PRIVATE
  -fexceptions
  -frtti
  -O2
  -DONANDROID
)
