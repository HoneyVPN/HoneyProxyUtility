# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(HoneyProxyUtility LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "HoneyProxyUtility")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

# Ship the compiler's redistributable runtime beside the UI and Flutter DLLs.
# A fresh Windows machine may not have a global Visual C++ runtime installed.
if(MSVC)
  set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
  set(CMAKE_INSTALL_DEBUG_LIBRARIES FALSE)
  include(InstallRequiredSystemLibraries)
  foreach(HONEY_REQUIRED_RUNTIME msvcp140.dll vcruntime140.dll vcruntime140_1.dll)
    set(HONEY_RUNTIME_FOUND FALSE)
    foreach(HONEY_RUNTIME_FILE IN LISTS CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
      get_filename_component(HONEY_RUNTIME_NAME "${HONEY_RUNTIME_FILE}" NAME)
      string(TOLOWER "${HONEY_RUNTIME_NAME}" HONEY_RUNTIME_NAME)
      if(HONEY_RUNTIME_NAME STREQUAL HONEY_REQUIRED_RUNTIME)
        set(HONEY_RUNTIME_FOUND TRUE)
      endif()
    endforeach()
    if(NOT HONEY_RUNTIME_FOUND)
      message(FATAL_ERROR "The MSVC redistributable ${HONEY_REQUIRED_RUNTIME} is missing")
    endif()
  endforeach()
  install(PROGRAMS ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    CONFIGURATIONS Profile;Release COMPONENT Runtime)
endif()

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/runner/windows_vpn_supervisor.ps1"
  "${CMAKE_CURRENT_SOURCE_DIR}/runner/windows_proxy_settings.cs"
  "${CMAKE_CURRENT_SOURCE_DIR}/service/DesktopUserIdentity.cs"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)

# The privileged broker is a fixed service executable installed beside the UI.
# It is compiled from reviewed sources, never downloaded as an opaque helper.
find_program(HONEY_POWERSHELL_EXECUTABLE NAMES powershell.exe)
if(NOT HONEY_POWERSHELL_EXECUTABLE)
  message(FATAL_ERROR "Windows PowerShell is required to compile the VPN service")
endif()
set(HONEY_SERVICE_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/windows-service/HoneyVpnService.exe")
add_custom_command(OUTPUT "${HONEY_SERVICE_OUTPUT}"
  COMMAND "${HONEY_POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive
    -ExecutionPolicy Bypass -File "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/build_windows_service.ps1"
    -SourceDirectory "${CMAKE_CURRENT_SOURCE_DIR}/service"
    -OutputDirectory "${CMAKE_CURRENT_BINARY_DIR}/windows-service"
  DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/service/HoneyVpnService.cs"
    "${CMAKE_CURRENT_SOURCE_DIR}/service/SafeTunConfiguration.cs"
    "${CMAKE_CURRENT_SOURCE_DIR}/service/ProviderGeoRuleSetValidator.cs"
    "${CMAKE_CURRENT_SOURCE_DIR}/service/KernelEpoch.cs"
    "${CMAKE_CURRENT_SOURCE_DIR}/service/DesktopUserIdentity.cs"
    "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/build_windows_service.ps1"
  VERBATIM)
add_custom_target(honey_windows_service ALL DEPENDS "${HONEY_SERVICE_OUTPUT}")
install(FILES "${HONEY_SERVICE_OUTPUT}"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
