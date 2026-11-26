cmake_minimum_required(VERSION 3.20)
project(cpp_agent LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    add_compile_options(/W4 /permissive- /utf-8 /EHsc)
endif()

find_package(Threads REQUIRED)
add_library(agent-core STATIC
    src/core/agent.cpp
    src/core/input.cpp
    src/core/multi_session.cpp
    src/core/session_worker.cpp
    src/protocol/ndjson.cpp)
target_include_directories(agent-core PUBLIC include)
target_include_directories(agent-core SYSTEM PUBLIC third_party)
target_link_libraries(agent-core PUBLIC Threads::Threads)

if(WIN32)
    add_executable(cpp-agent src/main.cpp src/windows/uia_adapter.cpp src/windows/jab_adapter.cpp src/windows/msaa_adapter.cpp
        src/windows/input_driver.cpp src/windows/cpp-agent.manifest)
    target_compile_definitions(cpp-agent PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
    target_link_libraries(cpp-agent PRIVATE agent-core ole32 oleaut32 oleacc user32 advapi32 uiautomationcore)
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(agent-core-test tests/core_test.cpp)
    target_link_libraries(agent-core-test PRIVATE agent-core)
    add_test(NAME agent-core-contract COMMAND agent-core-test)
    add_executable(input-contract-test tests/input_test.cpp)
    target_link_libraries(input-contract-test PRIVATE agent-core)
    add_test(NAME input-contract COMMAND input-contract-test)
    if(WIN32)
        add_executable(msaa-identity-fixture ../../tests/fixtures/accessibility/msaa-identity-fixture.cpp)
        target_compile_definitions(msaa-identity-fixture PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
        target_link_libraries(msaa-identity-fixture PRIVATE oleacc oleaut32 ole32 user32 uuid)
        # Reads the input environment only. It sends no input and installs no hook.
        add_executable(input-driver-check tests/input_driver_check.cpp src/windows/input_driver.cpp
            src/windows/cpp-agent.manifest)
        target_compile_definitions(input-driver-check PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
        target_link_libraries(input-driver-check PRIVATE agent-core user32 advapi32)
        add_test(NAME input-driver-status COMMAND input-driver-check)
    endif()
endif()
