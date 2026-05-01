# Helper: create a named test executable linked against all bitta modules and gtest.
# Usage: bitta_test(test_signal test_signal.cpp)
function(bitta_test NAME)
    add_executable(${NAME} ${ARGN})
    target_link_libraries(${NAME} PRIVATE
        bitta::core
        bitta::trace
        bitta::contract
        bitta::component
        GTest::gtest_main
    )
    gtest_discover_tests(${NAME})
endfunction()

bitta_test(smoke_test smoke_test.cpp)
