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
    src/core/session_worker.cpp
    src/protocol/ndjson.cpp)
target_include_directories(agent-core PUBLIC include)
target_include_directories(agent-core SYSTEM PUBLIC third_party)
target_link_libraries(agent-core PUBLIC Threads::Threads)

if(WIN32)
    add_executable(cpp-agent src/main.cpp src/windows/uia_adapter.cpp)
    target_compile_definitions(cpp-agent PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
    target_link_libraries(cpp-agent PRIVATE agent-core ole32 oleaut32 user32 uiautomationcore)
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(agent-core-test tests/core_test.cpp)
    target_link_libraries(agent-core-test PRIVATE agent-core)
    add_test(NAME agent-core-contract COMMAND agent-core-test)
endif()
