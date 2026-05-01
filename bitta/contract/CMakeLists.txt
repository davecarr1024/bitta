# bitta::contract — judgment layer
# Depends on: bitta::trace (and transitively bitta::core)

add_library(bitta_contract INTERFACE)
add_library(bitta::contract ALIAS bitta_contract)

target_include_directories(bitta_contract INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)
target_link_libraries(bitta_contract INTERFACE
    bitta::trace
    bitta::compile_options
)
