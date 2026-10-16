#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "noodlet/instance",
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  instance_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Saving every torrent on exit takes a few seconds. The window goes away at
  // once and the process finishes that work unseen.
  if (message == WM_CLOSE) {
    ::ShowWindow(hwnd, SW_HIDE);
  }

  // A .torrent file or magnet link opened while NoodleT is running: the new
  // process sends it here and quits (see main.cpp).
  if (message == WM_COPYDATA) {
    const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (data->dwData == kForwardedArgumentsMessage && instance_channel_) {
      const char* bytes = static_cast<const char*>(data->lpData);
      flutter::EncodableList arguments;
      size_t start = 0;
      for (size_t i = 0; i < data->cbData; ++i) {
        if (bytes[i] == '\0') {
          arguments.emplace_back(std::string(bytes + start, i - start));
          start = i + 1;
        }
      }
      instance_channel_->InvokeMethod(
          "open",
          std::make_unique<flutter::EncodableValue>(std::move(arguments)));
      return TRUE;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
