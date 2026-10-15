cmake_minimum_required(VERSION 3.14)
project(windows_service_client_test LANGUAGES CXX)
add_executable(windows_service_client_test
  "windows_service_client_test.cpp"
  "../../../windows/runner/windows_service_client.cpp"
  "../../../windows/runner/windows_session_path.cpp")
target_compile_features(windows_service_client_test PRIVATE cxx_std_17)
target_compile_definitions(windows_service_client_test PRIVATE
  NOMINMAX UNICODE _UNICODE HONEY_SERVICE_CLIENT_TESTING)
target_link_libraries(windows_service_client_test PRIVATE "advapi32.lib" "user32.lib")
if(MSVC)
  target_compile_options(windows_service_client_test PRIVATE /W4 /WX /EHsc /utf-8)
endif()
