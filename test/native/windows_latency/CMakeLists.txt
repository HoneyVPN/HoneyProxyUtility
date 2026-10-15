cmake_minimum_required(VERSION 3.14)
project(windows_latency_fixture LANGUAGES CXX)
add_executable(windows_latency_process_test
  windows_latency_process_test.cpp
  ../../../windows/runner/windows_latency_process.cpp
  ../../../windows/runner/windows_session_path.cpp)
target_compile_features(windows_latency_process_test PRIVATE cxx_std_17)
target_compile_definitions(windows_latency_process_test PRIVATE NOMINMAX)
target_include_directories(windows_latency_process_test PRIVATE ../../../windows/runner)
target_link_libraries(windows_latency_process_test PRIVATE advapi32 user32)
if(MSVC)
  target_compile_options(windows_latency_process_test PRIVATE /W4 /WX /EHsc)
endif()
