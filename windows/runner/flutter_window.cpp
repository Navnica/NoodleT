#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windowsx.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

// Clicks on the notification area icon.
constexpr UINT kTrayIconMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;

// Items of the tray menu.
constexpr UINT kMenuOpen = 1;
constexpr UINT kMenuExit = 2;

// Sent to every top-level window when Explorer restarts; the icon it showed
// is gone and has to be added again.
const UINT kTaskbarCreated = ::RegisterWindowMessageW(L"TaskbarCreated");

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size = static_cast<int>(utf8.size());
  const int length =
      ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, nullptr, 0);
  std::wstring utf16(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, utf16.data(), length);
  return utf16;
}

// The string under |key| in the arguments of a channel call, or "" if absent.
std::wstring StringArgument(const flutter::EncodableMap& arguments,
                            const char* key) {
  auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) {
    return std::wstring();
  }
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? Utf16FromUtf8(*value) : std::wstring();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  if (tray_icon_) {
    ::DestroyIcon(tray_icon_);
  }
}

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
  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "noodlet/tray",
          &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleTrayCall(call, std::move(result));
      });
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
  RemoveTrayIcon();
  tray_channel_ = nullptr;
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
  if (message == WM_CLOSE) {
    // With the tray on, closing only hides the window; downloads go on.
    if (tray_enabled_ && !quitting_) {
      HideToTray();
      return 0;
    }
    // Saving every torrent on exit takes a few seconds. The window goes away
    // at once and the process finishes that work unseen.
    RemoveTrayIcon();
    ::ShowWindow(hwnd, SW_HIDE);
  }

  // Shown again, by the tray icon or by a second launch (see main.cpp).
  if (message == WM_SHOWWINDOW && wparam) {
    ::RemovePropW(hwnd, kInTrayProperty);
  }

  if (message == kTrayIconMessage) {
    switch (LOWORD(lparam)) {
      case NIN_SELECT:
      case NIN_KEYSELECT:
        RestoreFromTray();
        break;
      case WM_CONTEXTMENU:
        ShowTrayMenu({GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)});
        break;
    }
    return 0;
  }

  if (message == kTaskbarCreated && tray_enabled_) {
    tray_icon_added_ = false;
    AddTrayIcon();
    return 0;
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

void FlutterWindow::HandleTrayCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "configure") {
    const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("bad_arguments");
      return;
    }
    tray_open_text_ = StringArgument(*arguments, "open");
    tray_exit_text_ = StringArgument(*arguments, "exit");
    hidden_title_ = StringArgument(*arguments, "hiddenTitle");
    hidden_text_ = StringArgument(*arguments, "hiddenText");
    auto enabled = arguments->find(flutter::EncodableValue("enabled"));
    tray_enabled_ = enabled != arguments->end() &&
                    std::get_if<bool>(&enabled->second) != nullptr &&
                    std::get<bool>(enabled->second);
    if (tray_enabled_) {
      AddTrayIcon();
    } else {
      RemoveTrayIcon();
    }
    result->Success();
  } else if (call.method_name() == "tooltip") {
    const auto* text = std::get_if<std::string>(call.arguments());
    tray_tooltip_ = text ? Utf16FromUtf8(*text) : L"NoodleT";
    UpdateTrayTooltip();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_) {
    return;
  }
  if (tray_icon_ == nullptr) {
    tray_icon_ = static_cast<HICON>(::LoadImageW(
        ::GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
        IMAGE_ICON, ::GetSystemMetrics(SM_CXSMICON),
        ::GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayIconMessage;
  data.hIcon = tray_icon_;
  wcsncpy_s(data.szTip, tray_tooltip_.c_str(), _TRUNCATE);
  if (!::Shell_NotifyIconW(NIM_ADD, &data)) {
    return;
  }
  tray_icon_added_ = true;
  // Reports clicks as NIN_SELECT and WM_CONTEXTMENU with the click position.
  data.uVersion = NOTIFYICON_VERSION_4;
  ::Shell_NotifyIconW(NIM_SETVERSION, &data);
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  tray_icon_added_ = false;
}

void FlutterWindow::UpdateTrayTooltip() {
  if (!tray_icon_added_) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  data.uFlags = NIF_TIP | NIF_SHOWTIP;
  wcsncpy_s(data.szTip, tray_tooltip_.c_str(), _TRUNCATE);
  ::Shell_NotifyIconW(NIM_MODIFY, &data);
}

void FlutterWindow::HideToTray() {
  HWND hwnd = GetHandle();
  ::ShowWindow(hwnd, SW_HIDE);
  ::SetPropW(hwnd, kInTrayProperty, reinterpret_cast<HANDLE>(1));

  // Windows 11 tucks new icons away under the arrow, so without a word the
  // hidden window looks like a closed one.
  if (!hidden_hint_shown_ && tray_icon_added_ && !hidden_text_.empty()) {
    hidden_hint_shown_ = true;
    NOTIFYICONDATAW data{};
    data.cbSize = sizeof(data);
    data.hWnd = hwnd;
    data.uID = kTrayIconId;
    data.uFlags = NIF_INFO;
    data.dwInfoFlags = NIIF_INFO;
    wcsncpy_s(data.szInfoTitle, hidden_title_.c_str(), _TRUNCATE);
    wcsncpy_s(data.szInfo, hidden_text_.c_str(), _TRUNCATE);
    ::Shell_NotifyIconW(NIM_MODIFY, &data);
  }
}

void FlutterWindow::RestoreFromTray() {
  HWND hwnd = GetHandle();
  ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(hwnd);
}

void FlutterWindow::ShowTrayMenu(POINT at) {
  HWND hwnd = GetHandle();
  HMENU menu = ::CreatePopupMenu();
  ::AppendMenuW(menu, MF_STRING, kMenuOpen, tray_open_text_.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuExit, tray_exit_text_.c_str());
  ::SetMenuDefaultItem(menu, kMenuOpen, FALSE);
  // Otherwise the menu stays open when the user clicks elsewhere.
  ::SetForegroundWindow(hwnd);
  const UINT command = static_cast<UINT>(
      ::TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                       at.x, at.y, 0, hwnd, nullptr));
  ::DestroyMenu(menu);
  if (command == kMenuOpen) {
    RestoreFromTray();
  } else if (command == kMenuExit) {
    Quit();
  }
}

void FlutterWindow::Quit() {
  quitting_ = true;
  // A second launch now waits for this one to finish instead of showing it.
  ::RemovePropW(GetHandle(), kInTrayProperty);
  ::PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
}
