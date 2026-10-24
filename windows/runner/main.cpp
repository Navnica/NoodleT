#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Hands the command line of this launch (.torrent paths and magnet links, e.g.
// a file opened from Explorer) to the NoodleT that is already open, which adds
// them as if they had been dropped onto its window.
void ForwardArguments(HWND existing) {
  std::string payload;
  for (const std::string& argument : GetCommandLineArguments()) {
    payload += argument;
    payload.push_back('\0');
  }
  if (payload.empty()) {
    return;
  }
  COPYDATASTRUCT data{};
  data.dwData = kForwardedArgumentsMessage;
  data.cbData = static_cast<DWORD>(payload.size());
  data.lpData = payload.data();
  ::SendMessageTimeoutW(existing, WM_COPYDATA, 0,
                        reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG,
                        5000, nullptr);
}

// Lets one NoodleT run at a time, since two would fight over the same
// torrents. Returns false when another one is open; its window is brought to
// the front (out of the tray if need be) and given this launch's arguments
// instead. An instance that is still saving after its window was closed is
// waited for.
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
    // A hidden window is either in the tray, which counts as open, or saving
    // before it quits, which is waited for.
    const bool in_tray =
        existing != nullptr && ::GetPropW(existing, kInTrayProperty) != nullptr;
    if (existing != nullptr && (::IsWindowVisible(existing) || in_tray)) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      } else if (in_tray) {
        ::ShowWindow(existing, SW_SHOW);
      }
      ::SetForegroundWindow(existing);
      ForwardArguments(existing);
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
  Win32Window::Size size(1100, 740);
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
