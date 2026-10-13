#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Lets one NoodleT run at a time, since two would fight over the same
// torrents. Returns false when another one is open; its window is brought to
// the front instead. An instance that is still saving after its window was
// closed is waited for.
bool AcquireSingleInstance() {
  // A separate data folder is a separate, independent copy.
  if (::GetEnvironmentVariableW(L"NOODLET_DATA_DIR", nullptr, 0) > 0) {
    return true;
  }
  HANDLE mutex = ::CreateMutexW(nullptr, FALSE, L"NoodleT.SingleInstance");
  if (mutex == nullptr) {
    return true;
  }
  for (int waited_ms = 0; waited_ms < 60000; waited_ms += 200) {
    // Never released on purpose: the system frees it when the process ends.
    if (::WaitForSingleObject(mutex, 200) != WAIT_TIMEOUT) {
      return true;
    }
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"NoodleT");
    if (existing != nullptr && ::IsWindowVisible(existing)) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
      return false;
    }
  }
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  if (!AcquireSingleInstance()) {
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(480, 780);
  if (!window.Create(L"NoodleT", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
