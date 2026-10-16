#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// Marks the WM_COPYDATA message in which a second launch of NoodleT hands its
// command line over to the open window: UTF-8 arguments, each ended by '\0'.
constexpr ULONG_PTR kForwardedArgumentsMessage = 0x4E6F6F64;  // "Nood"

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
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Passes the arguments of later launches on to Dart.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      instance_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
