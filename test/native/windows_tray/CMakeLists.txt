cmake_minimum_required(VERSION 3.14)
project(windows_tray_fixture LANGUAGES CXX)
add_executable(windows_tray_test
  windows_tray_test.cpp
  ../../../windows/runner/windows_tray.cpp
  ../../../windows/runner/windows_tray_flags.cpp)
target_compile_features(windows_tray_test PRIVATE cxx_std_17)
if(WIN32)
  target_sources(windows_tray_test PRIVATE tray_test.rc)
  add_custom_command(TARGET windows_tray_test POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
      "$<TARGET_FILE_DIR:windows_tray_test>/data/flutter_assets/assets/flags/noto"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${CMAKE_CURRENT_SOURCE_DIR}/../../../assets/flags/noto/fi.png"
      "$<TARGET_FILE_DIR:windows_tray_test>/data/flutter_assets/assets/flags/noto/fi.png")
  target_compile_definitions(windows_tray_test PRIVATE NOMINMAX UNICODE _UNICODE)
  target_link_libraries(windows_tray_test PRIVATE shell32 user32 windowscodecs ole32 gdi32)
endif()
if(MSVC)
  target_compile_options(windows_tray_test PRIVATE /W4 /WX /EHsc /utf-8)
else()
  target_compile_options(windows_tray_test PRIVATE -Wall -Wextra -Werror)
endif()
