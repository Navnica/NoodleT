#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "win32_window.h"

// Marks the WM_COPYDATA message in which a second launch of NoodleT hands its
// command line over to the open window: UTF-8 arguments, each ended by '\0'.
constexpr ULONG_PTR kForwardedArgumentsMessage = 0x4E6F6F64;  // "Nood"

// Set on the window while it is hidden in the notification area, so that a
// second launch shows it instead of taking it for one that is quitting.
constexpr wchar_t kInTrayProperty[] = L"NoodleT.InTray";

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The notification area icon, driven from lib/tray.dart over the
  // noodlet/tray channel. While it is on, closing the window only hides it.
  void HandleTrayCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void AddTrayIcon();
  void RemoveTrayIcon();
  void UpdateTrayTooltip();
  void HideToTray();
  void RestoreFromTray();
  void ShowTrayMenu(POINT at);
  // Closes the window for good: the process saves the torrents and exits.
  void Quit();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Passes the arguments of later launches on to Dart.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      instance_channel_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      tray_channel_;
  HICON tray_icon_ = nullptr;
  // The "close to tray" setting.
  bool tray_enabled_ = false;
  bool tray_icon_added_ = false;
  // Set by the Exit item of the tray menu, so that WM_CLOSE really closes.
  bool quitting_ = false;
  // The "still running" notification appears on the first hide only.
  bool hidden_hint_shown_ = false;
  // Texts in the language of the interface, sent by Dart.
  std::wstring tray_tooltip_ = L"NoodleT";
  std::wstring tray_open_text_;
  std::wstring tray_exit_text_;
  std::wstring hidden_title_;
  std::wstring hidden_text_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
