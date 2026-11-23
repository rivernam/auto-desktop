cmake_minimum_required(VERSION 3.20)
project(AutoDesktopMsaaProbe LANGUAGES CXX)

add_executable(msaa-probe msaa_probe.cpp)
target_compile_features(msaa-probe PRIVATE cxx_std_17)
target_compile_definitions(msaa-probe PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(msaa-probe PRIVATE /W4 /permissive-)
target_include_directories(msaa-probe SYSTEM PRIVATE ../../../native/cpp-agent/third_party)
target_link_libraries(msaa-probe PRIVATE oleacc ole32 oleaut32)

set(FIXTURE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/.." CACHE PATH "Directory for the probe executable")
set_target_properties(msaa-probe PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${FIXTURE_OUTPUT_DIRECTORY}/$<0:>")
