cmake_minimum_required(VERSION 3.14)
project(windows_session_path_test LANGUAGES CXX)
add_executable(windows_session_path_test
  "windows_session_path_test.cpp"
  "../../../windows/runner/windows_session_path.cpp")
target_compile_features(windows_session_path_test PRIVATE cxx_std_17)
target_link_libraries(windows_session_path_test PRIVATE "advapi32.lib" "user32.lib")
target_compile_definitions(windows_session_path_test PRIVATE NOMINMAX)
if(MSVC)
  target_compile_options(windows_session_path_test PRIVATE /W4 /WX /EHsc /utf-8)
endif()
