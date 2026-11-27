cmake_minimum_required(VERSION 3.21)

cmake_policy(SET CMP0091 NEW)
project(ccbuddy_preinstalled_entry_shim LANGUAGES C)

if(NOT MSVC)
  message(FATAL_ERROR "CCbuddy preinstalled entry shim must be built with MSVC")
endif()
if(NOT DEFINED CCBUDDY_SHIM_OUTPUT_DIR)
  message(FATAL_ERROR "Missing CCBUDDY_SHIM_OUTPUT_DIR")
endif()

# 静态链接 C 运行库：shim 复制到预装 bin 目录后独立运行，不依赖目标机器的 VC++ 运行库。
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

add_executable(ccbuddy-preinstalled-entry-shim shim.c)
target_compile_definitions(ccbuddy-preinstalled-entry-shim PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)
# /Brepro 去掉时间戳，同一源码产出相同字节；入口是否需要替换按 SHA-256 判断。
target_compile_options(ccbuddy-preinstalled-entry-shim PRIVATE /W4 /WX /utf-8 /guard:cf /Brepro)
target_link_options(ccbuddy-preinstalled-entry-shim PRIVATE /GUARD:CF /Brepro /SUBSYSTEM:CONSOLE)
set_target_properties(ccbuddy-preinstalled-entry-shim PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CCBUDDY_SHIM_OUTPUT_DIR}"
  RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CCBUDDY_SHIM_OUTPUT_DIR}"
)
