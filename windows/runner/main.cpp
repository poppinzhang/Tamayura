#include <winsock2.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_text.h"
#include "flutter_window.h"
#include "single_instance.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Claim ownership before plugins or Dart can open shared application data.
  tamayura::SingleInstance single_instance;
  const auto start = single_instance.Start();
  if (start == tamayura::SingleInstance::StartResult::kActivated) {
    return EXIT_SUCCESS;
  }
  if (start != tamayura::SingleInstance::StartResult::kPrimary) {
    MessageBoxW(nullptr,
                tamayura::app_text::Text(tamayura::TextId::kSingleInstanceFailed),
                tamayura::app_text::Text(tamayura::TextId::kTrayTooltip),
                MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com)) return EXIT_FAILURE;
  WSADATA sockets{};
  if (WSAStartup(MAKEWORD(2, 2), &sockets) != 0) {
    CoUninitialize();
    return EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, single_instance);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Tamayura", origin, size)) {
    single_instance.StopActivation();
    window.Destroy();
    WSACleanup();
    CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg{};
  BOOL received;
  while ((received = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  single_instance.StopActivation();
  window.Destroy();
  WSACleanup();
  ::CoUninitialize();
  return received == -1 ? EXIT_FAILURE : EXIT_SUCCESS;
}
