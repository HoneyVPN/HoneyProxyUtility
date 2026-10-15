cmake_minimum_required(VERSION 3.14)
project(windows_import_fixture LANGUAGES CXX)
add_executable(windows_import_test
  windows_import_test.cpp
  ../../../windows/runner/windows_deeplink.cpp)
target_compile_features(windows_import_test PRIVATE cxx_std_17)
target_compile_definitions(windows_import_test PRIVATE HONEY_DEEPLINK_TESTING)
if(WIN32)
  # Exercise the actual production converter without loading a Flutter engine.
  target_sources(windows_import_test PRIVATE ../../../windows/runner/windows_utf8.cpp)
  target_compile_definitions(windows_import_test PRIVATE NOMINMAX UNICODE _UNICODE)
  target_link_libraries(windows_import_test PRIVATE advapi32 user32 shell32)
endif()
if(MSVC)
  target_compile_options(windows_import_test PRIVATE /W4 /WX /EHsc /utf-8)
else()
  target_compile_options(windows_import_test PRIVATE -Wall -Wextra -Werror)
endif()
