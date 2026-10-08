cmake_minimum_required(VERSION 3.15)
project(vityo_windows_pipe LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "vityo_windows_pipe is a Windows-only native library")
endif()

add_library(vityo_windows_pipe SHARED windows_pipe.cpp)
target_compile_features(vityo_windows_pipe PRIVATE cxx_std_17)
target_compile_definitions(vityo_windows_pipe PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
if(MSVC)
  target_compile_options(vityo_windows_pipe PRIVATE /W4 /WX)
  # No additional VC runtime DLL needs to be found or shipped for this shim.
  set_property(TARGET vityo_windows_pipe PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
endif()
# One native boundary captures the API result and last-error together. No Dart,
# Flutter, package, or daemon linkage is needed by this app-owned shim.
