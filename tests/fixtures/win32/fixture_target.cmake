set(FIXTURE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/.." CACHE PATH "Directory for the fixture executable")

function(configure_fixture target)
    target_compile_features(${target} PRIVATE cxx_std_17)
    target_compile_definitions(${target} PRIVATE UNICODE _UNICODE NOMINMAX)
    target_compile_options(${target} PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/W4 /permissive->)
    target_link_libraries(${target} PRIVATE comctl32 shell32)
    set_target_properties(${target} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${FIXTURE_OUTPUT_DIRECTORY}/$<0:>")
endfunction()
