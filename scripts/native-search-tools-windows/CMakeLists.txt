cmake_minimum_required(VERSION 3.21)

cmake_policy(SET CMP0091 NEW)
project(ccbuddy_native_ugrep LANGUAGES C CXX)

if(NOT MSVC)
  message(FATAL_ERROR "CCbuddy Windows ugrep must be built with MSVC")
endif()

foreach(source_name UGREP PCRE2 ZLIB BZIP2 ZSTD BROTLI)
  if(NOT DEFINED CCBUDDY_${source_name}_SOURCE_DIR)
    message(FATAL_ERROR "Missing CCBUDDY_${source_name}_SOURCE_DIR")
  endif()
endforeach()

if(NOT DEFINED CCBUDDY_UGREP_OUTPUT_DIR)
  message(FATAL_ERROR "Missing CCBUDDY_UGREP_OUTPUT_DIR")
endif()

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)

# 随机构建目录不能进入最终 PE，否则同版本工具无法跨 CLI 复用同一份 runtime cache。
if(DEFINED CCBUDDY_BUILD_PATH)
  add_compile_options("/pathmap:${CCBUDDY_BUILD_PATH}=ccbuddy-native-search")
endif()

set(BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(PCRE2_BUILD_PCRE2_8 ON CACHE BOOL "" FORCE)
set(PCRE2_BUILD_PCRE2_16 OFF CACHE BOOL "" FORCE)
set(PCRE2_BUILD_PCRE2_32 OFF CACHE BOOL "" FORCE)
set(PCRE2_BUILD_PCRE2GREP OFF CACHE BOOL "" FORCE)
set(PCRE2_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(PCRE2_SHOW_REPORT OFF CACHE BOOL "" FORCE)
set(PCRE2_STATIC_RUNTIME ON CACHE BOOL "" FORCE)
set(PCRE2_SUPPORT_JIT ON CACHE BOOL "" FORCE)
add_subdirectory("${CCBUDDY_PCRE2_SOURCE_DIR}" pcre2 EXCLUDE_FROM_ALL)

set(SKIP_INSTALL_ALL ON CACHE BOOL "" FORCE)
add_subdirectory("${CCBUDDY_ZLIB_SOURCE_DIR}" zlib EXCLUDE_FROM_ALL)

add_library(ccbuddy_bzip2 STATIC
  "${CCBUDDY_BZIP2_SOURCE_DIR}/blocksort.c"
  "${CCBUDDY_BZIP2_SOURCE_DIR}/huffman.c"
  "${CCBUDDY_BZIP2_SOURCE_DIR}/crctable.c"
  "${CCBUDDY_BZIP2_SOURCE_DIR}/randtable.c"
  "${CCBUDDY_BZIP2_SOURCE_DIR}/compress.c"
  "${CCBUDDY_BZIP2_SOURCE_DIR}/decompress.c"
  "${CCBUDDY_BZIP2_SOURCE_DIR}/bzlib.c"
)
target_compile_definitions(ccbuddy_bzip2 PRIVATE _CRT_SECURE_NO_WARNINGS)
target_include_directories(ccbuddy_bzip2 PUBLIC "${CCBUDDY_BZIP2_SOURCE_DIR}")

set(ZSTD_BUILD_CONTRIB OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_STATIC ON CACHE BOOL "" FORCE)
set(ZSTD_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(ZSTD_USE_STATIC_RUNTIME ON CACHE BOOL "" FORCE)
add_subdirectory("${CCBUDDY_ZSTD_SOURCE_DIR}/build/cmake" zstd EXCLUDE_FROM_ALL)

set(BROTLI_BUNDLED_MODE ON CACHE BOOL "" FORCE)
add_subdirectory("${CCBUDDY_BROTLI_SOURCE_DIR}" brotli EXCLUDE_FROM_ALL)

set(CCBUDDY_VIIZ_SOURCE_DIR "${CCBUDDY_UGREP_SOURCE_DIR}/lzma/C")
add_library(ccbuddy_viiz STATIC
  "${CCBUDDY_VIIZ_SOURCE_DIR}/viizip.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/7zAlloc.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/7zArcIn.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/7zBuf.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/7zBuf2.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/7zCrc.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/7zCrcOpt.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/7zDec.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/7zFile.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/7zStream.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/Bcj2.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/Bra.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/Bra86.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/BraIA64.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/CpuArch.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/Delta.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/Lzma2Dec.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/LzmaDec.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/Ppmd7.c"
  "${CCBUDDY_VIIZ_SOURCE_DIR}/Ppmd7Dec.c"
)
target_compile_definitions(ccbuddy_viiz PRIVATE
  Z7_PPMD_SUPPORT
  Z7_EXTRACT_ONLY
  NDEBUG
  _CRT_SECURE_NO_WARNINGS
)
target_include_directories(ccbuddy_viiz PUBLIC "${CCBUDDY_VIIZ_SOURCE_DIR}")

set(CCBUDDY_REFLEX_SOURCES
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/block_scripts.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/composer.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/convert.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/debug.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/error.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/input.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/language_scripts.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/letter_case.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/letter_scripts.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/matcher.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/pattern.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/posix.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/simd.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/unicode.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/lib/utf8.cpp"
)

add_library(ccbuddy_reflex STATIC ${CCBUDDY_REFLEX_SOURCES})
target_compile_definitions(ccbuddy_reflex PRIVATE WITH_NO_CODEGEN)

add_executable(ugrep
  "${CCBUDDY_UGREP_SOURCE_DIR}/src/ugrep.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/src/cnf.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/src/glob.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/src/output.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/src/query.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/src/screen.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/src/stats.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/src/vkey.cpp"
  "${CCBUDDY_UGREP_SOURCE_DIR}/src/zopen.c"
)

add_library(ccbuddy_ugrep_contract INTERFACE)
target_compile_definitions(ccbuddy_ugrep_contract INTERFACE
  HAVE_LIBBROTLI
  HAVE_LIBBZ2
  HAVE_LIBZ
  HAVE_LIBZSTD
  HAVE_PCRE2
  NDEBUG
  PCRE2_STATIC
  WITH_COLOR
  WITH_NO_INDENT
  _CONSOLE
  _CRT_NONSTDC_NO_WARNINGS
  _CRT_SECURE_NO_WARNINGS
)
if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
  target_compile_definitions(ccbuddy_ugrep_contract INTERFACE HAVE_NEON)
else()
  target_compile_definitions(ccbuddy_ugrep_contract INTERFACE HAVE_SSE2)
endif()
target_compile_features(ccbuddy_ugrep_contract INTERFACE cxx_std_17)
# ugrep 固定源码是无 BOM UTF-8；中文 Windows 按 CP936 解析时会触发 C4819/C1070，并改写 UTF-8 字符串字面量。
target_compile_options(ccbuddy_ugrep_contract INTERFACE
  /utf-8
  $<$<COMPILE_LANGUAGE:CXX>:/EHsc>
)
target_include_directories(ccbuddy_ugrep_contract INTERFACE
  "${CCBUDDY_UGREP_SOURCE_DIR}/include"
  "${CCBUDDY_UGREP_SOURCE_DIR}/src"
  "${CCBUDDY_VIIZ_SOURCE_DIR}"
)

target_link_libraries(ccbuddy_reflex PRIVATE ccbuddy_ugrep_contract pcre2-8-static)
target_link_libraries(ugrep PRIVATE
  ccbuddy_ugrep_contract
  ccbuddy_reflex
  ccbuddy_viiz
  pcre2-8-static
  zlibstatic
  ccbuddy_bzip2
  libzstd_static
  brotlienc
  brotlidec
  brotlicommon
)
target_link_options(ugrep PRIVATE /Brepro)
set_target_properties(ugrep PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CCBUDDY_UGREP_OUTPUT_DIR}"
  RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CCBUDDY_UGREP_OUTPUT_DIR}"
)
