cmake_minimum_required(VERSION 3.21)
project(bitta LANGUAGES CXX)

# ── Language ─────────────────────────────────────────────────────────────────

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ── Warnings (applied to all bitta targets, not to vendored deps) ─────────────

add_library(bitta_compile_options INTERFACE)
add_library(bitta::compile_options ALIAS bitta_compile_options)
target_compile_options(bitta_compile_options INTERFACE
    -Wall
    -Wextra
    -Wpedantic
    -Wshadow
    -Wconversion
    -Werror
)

# ── Google Test ───────────────────────────────────────────────────────────────

include(FetchContent)
FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.14.0
    GIT_SHALLOW    TRUE
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)
include(GoogleTest)

# ── Subdirectories ────────────────────────────────────────────────────────────

enable_testing()
add_subdirectory(bitta)
add_subdirectory(tests)
