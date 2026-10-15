cmake_minimum_required(VERSION 3.14)
project(window_placement_fixture LANGUAGES CXX)
add_executable(window_placement_test
  window_placement_test.cpp
  ../../../windows/runner/window_placement.cpp)
target_compile_features(window_placement_test PRIVATE cxx_std_17)
if(WIN32)
  # Use the packaged application's DPI manifest before Flutter's DLL loads.
  target_sources(window_placement_test PRIVATE
    ../../../windows/runner/runner.exe.manifest)
  # Use the exact Flutter monitor-DPI utility used by the packaged application.
  set(FLUTTER_EPHEMERAL "${CMAKE_CURRENT_SOURCE_DIR}/../../../windows/flutter/ephemeral")
  target_include_directories(window_placement_test PRIVATE "${FLUTTER_EPHEMERAL}")
  target_link_libraries(window_placement_test PRIVATE
    user32 "${FLUTTER_EPHEMERAL}/flutter_windows.dll.lib")
  target_compile_definitions(window_placement_test PRIVATE NOMINMAX UNICODE _UNICODE)
  add_custom_command(TARGET window_placement_test POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${FLUTTER_EPHEMERAL}/flutter_windows.dll" "$<TARGET_FILE_DIR:window_placement_test>"
    VERBATIM)
endif()
if(MSVC)
  target_compile_options(window_placement_test PRIVATE /W4 /WX /EHsc)
else()
  target_compile_options(window_placement_test PRIVATE -Wall -Wextra -Werror)
endif()
