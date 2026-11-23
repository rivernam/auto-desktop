cmake_minimum_required(VERSION 3.20)
project(AutoDesktopWin32Fixture LANGUAGES CXX RC)

add_executable(win32 WIN32 fixture.cpp fixture.rc)
include(fixture_target.cmake)
configure_fixture(win32)
