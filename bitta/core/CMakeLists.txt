# bitta::core — physics layer
# Depends on nothing else in bitta.
#
# Currently INTERFACE (header-only). When .cpp sources are added under src/,
# change to STATIC and add: file(GLOB_RECURSE SOURCES "src/*.cpp")

add_library(bitta_core INTERFACE)
add_library(bitta::core ALIAS bitta_core)

target_include_directories(bitta_core INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)
target_link_libraries(bitta_core INTERFACE bitta::compile_options)
