# Static melonDS core + PokeDaisy pk_nds bridge for PocketDex iOS.
cmake_minimum_required(VERSION 3.16)
project(pknds_ios LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)

get_filename_component(ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(MELONDS_DIR "${ROOT}/upstream/third_party/melonds")
set(NDS_DIR "${ROOT}/upstream/app/src/main/cpp/nds")
set(IOS_NATIVE "${ROOT}/ios/Native")

if(NOT EXISTS "${MELONDS_DIR}/src/NDS.h")
  message(FATAL_ERROR "melonDS submodule missing — run: git -C upstream submodule update --init third_party/melonds")
endif()

set(BUILD_QT_SDL       OFF CACHE BOOL "" FORCE)
set(ENABLE_OGLRENDERER OFF CACHE BOOL "" FORCE)
set(ENABLE_GDBSTUB     OFF CACHE BOOL "" FORCE)
set(ENABLE_LTO_RELEASE OFF CACHE BOOL "" FORCE)
set(ENABLE_LTO         OFF CACHE BOOL "" FORCE)
# Interpreter only. Compiling melonDS JIT in (even with allow_jit off) constructs
# ARMJIT and takes exec memory — that hung or killed every DS boot on iOS.
set(ARCHITECTURE "ARM64" CACHE STRING "" FORCE)
set(ENABLE_JIT         OFF CACHE BOOL "" FORCE)
set(ENABLE_JIT_PROFILING OFF CACHE BOOL "" FORCE)
add_compile_definitions(ARCHITECTURE_ARM64=1)

include("${MELONDS_DIR}/../patches/apply_melonds_patch.cmake")
add_subdirectory("${MELONDS_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/melonds" EXCLUDE_FROM_ALL)

find_package(ZLIB REQUIRED)

add_library(pknds STATIC
  "${NDS_DIR}/pk_nds.cpp"
  "${NDS_DIR}/pk_nds_platform.cpp"
  "${NDS_DIR}/pk_nds_field.cpp"
  "${NDS_DIR}/pk_nds_field_gpu.cpp"
  "${NDS_DIR}/pk_nds_call.cpp"
  "${NDS_DIR}/pk_nds_call_melonds.cpp"
  "${NDS_DIR}/pk_nds_wide.cpp"
  "${NDS_DIR}/pk_nds_music.cpp"
  "${IOS_NATIVE}/pk_nds_gl_stub.cpp"
)

target_include_directories(pknds PUBLIC
  "${NDS_DIR}"
  "${IOS_NATIVE}/android_shim"
  "${MELONDS_DIR}/src"
)
target_include_directories(pknds PRIVATE
  "${IOS_NATIVE}"
)

target_compile_definitions(pknds PRIVATE ARCHITECTURE_ARM64=1)
target_compile_options(pknds PRIVATE
  -Wno-unused-parameter
  -Wno-unused-variable
  -Wno-unused-function
)

target_link_libraries(pknds PUBLIC core ZLIB::ZLIB)
target_link_libraries(pknds PRIVATE ${CMAKE_DL_LIBS})

set_target_properties(pknds PROPERTIES
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/Release-iphoneos"
)
