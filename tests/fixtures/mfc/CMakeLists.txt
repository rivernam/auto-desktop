cmake_minimum_required(VERSION 3.20)
project(AutoDesktopMfcFixture LANGUAGES CXX RC)

if(NOT MSVC OR NOT CMAKE_GENERATOR MATCHES "^Visual Studio")
    message(FATAL_ERROR "The MFC fixture requires the Visual Studio CMake generator and MSVC.")
endif()

get_filename_component(msvc_toolset "${CMAKE_CXX_COMPILER}/../../../.." ABSOLUTE)
if(CMAKE_VS_PLATFORM_NAME STREQUAL "Win32")
    set(mfc_architecture x86)
else()
    string(TOLOWER "${CMAKE_VS_PLATFORM_NAME}" mfc_architecture)
endif()
if(NOT EXISTS "${msvc_toolset}/atlmfc/include/afxwin.h" OR
   NOT EXISTS "${msvc_toolset}/atlmfc/lib/${mfc_architecture}/uafxcw.lib")
    message(FATAL_ERROR "Install the C++ MFC component for the selected MSVC toolset and architecture through Visual Studio Installer (Microsoft.VisualStudio.Component.VC.ATLMFC).")
endif()

set(CMAKE_MFC_FLAG 1)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
add_executable(mfc WIN32 fixture.cpp fixture.rc)
include(../win32/fixture_target.cmake)
configure_fixture(mfc)
