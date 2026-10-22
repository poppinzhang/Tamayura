cmake_minimum_required(VERSION 3.13)
project(tamayura_linux_native_tests LANGUAGES CXX)
enable_testing()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
option(TAMAYURA_SANITIZE "Build with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET glib-2.0 gio-2.0 gio-unix-2.0)
pkg_check_modules(PIXBUF REQUIRED IMPORTED_TARGET gdk-pixbuf-2.0)
pkg_check_modules(AVAHI REQUIRED IMPORTED_TARGET avahi-client)

set(RUNNER "${CMAKE_CURRENT_SOURCE_DIR}/../runner")

function(tamayura_test name)
  add_executable(${name} ${ARGN})
  target_include_directories(${name} PRIVATE "${RUNNER}" "${CMAKE_CURRENT_SOURCE_DIR}")
  target_compile_options(${name} PRIVATE -Wall -Wextra -Werror)
  target_link_libraries(${name} PRIVATE PkgConfig::GIO)
  if(TAMAYURA_SANITIZE)
    target_compile_options(${name} PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
    target_link_options(${name} PRIVATE -fsanitize=address,undefined)
  endif()
  add_test(NAME ${name} COMMAND ${name})
  set_tests_properties(${name} PROPERTIES TIMEOUT 300)
endfunction()

tamayura_test(linux_discovery_core_test discovery_core_test.cc
  "${RUNNER}/discovery_core.cc")
tamayura_test(linux_app_text_test app_text_test.cc "${RUNNER}/app_text.cc")
tamayura_test(linux_storage_test storage_test.cc
  "${RUNNER}/storage_core.cc" "${RUNNER}/app_text.cc")
tamayura_test(linux_thumbnail_cache_test thumbnail_cache_test.cc
  "${RUNNER}/storage_core.cc" "${RUNNER}/app_text.cc")
tamayura_test(linux_preview_test preview_test.cc
  "${RUNNER}/media_preview.cc" "${RUNNER}/storage_core.cc" "${RUNNER}/app_text.cc")
target_link_libraries(linux_preview_test PRIVATE PkgConfig::PIXBUF)
tamayura_test(linux_settings_test settings_test.cc
  "${RUNNER}/settings_store.cc" "${RUNNER}/storage_core.cc"
  "${RUNNER}/app_text.cc" "${RUNNER}/discovery_core.cc")
# Uses a private session bus from GIO's GTestDBus; skipped (77) without
# dbus-daemon.
tamayura_test(linux_desktop_tray_test desktop_tray_test.cc
  "${RUNNER}/desktop_tray.cc" "${RUNNER}/app_text.cc")
set_tests_properties(linux_desktop_tray_test PROPERTIES SKIP_RETURN_CODE 77)
# Registration and browsing need a running avahi-daemon; the rest always runs.
tamayura_test(linux_lan_discovery_test lan_discovery_test.cc
  "${RUNNER}/lan_discovery.cc" "${RUNNER}/main_dispatcher.cc"
  "${RUNNER}/discovery_core.cc" "${RUNNER}/storage_core.cc" "${RUNNER}/app_text.cc")
target_link_libraries(linux_lan_discovery_test PRIVATE PkgConfig::AVAHI)
set_tests_properties(linux_lan_discovery_test PROPERTIES SKIP_RETURN_CODE 77)
