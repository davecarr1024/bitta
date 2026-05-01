# bitta::component — composition layer
# Depends on: bitta::core, bitta::contract (and transitively bitta::trace)

add_library(bitta_component INTERFACE)
add_library(bitta::component ALIAS bitta_component)

target_include_directories(bitta_component INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)
target_link_libraries(bitta_component INTERFACE
    bitta::core
    bitta::contract
    bitta::compile_options
)
