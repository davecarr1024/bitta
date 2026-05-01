# bitta::trace — observation layer
# Depends on: bitta::core

add_library(bitta_trace INTERFACE)
add_library(bitta::trace ALIAS bitta_trace)

target_include_directories(bitta_trace INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)
target_link_libraries(bitta_trace INTERFACE
    bitta::core
    bitta::compile_options
)
