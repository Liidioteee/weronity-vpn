#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Per-session name: an elevated copy (VPN mode) and a normal one share it.
constexpr wchar_t kInstanceMutex[] = L"Local\\WeronityVpnClient.SingleInstance";
// Passed by the core when it relaunches the app elevated (elevate_windows.go).
constexpr wchar_t kRelaunchFlag[] = L"--relaunched";
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"Weronity";

// The app lives in the tray, so "start it again" is a normal thing to do. A
// second process would fight the first for the local data files and the proxy
// port — instead it brings the running window back and exits.
//
// Returns true when this process should exit. The mutex is deliberately never
// released: it is ours until the process ends.
bool AnotherInstanceIsRunning(const wchar_t *command_line) {
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, kInstanceMutex);
  if (mutex == nullptr || ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;  // we are the first (or cannot tell — then just start)
  }

  // Relaunched to gain admin rights: the instance that started us is exiting
  // right now. Wait for it to let go instead of mistaking it for a rival.
  const bool relaunched =
      command_line != nullptr && ::wcsstr(command_line, kRelaunchFlag);
  const DWORD wait = ::WaitForSingleObject(mutex, relaunched ? 5000 : 0);
  if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
    return false;  // the previous owner is gone; the mutex is ours now
  }

  if (HWND hwnd = ::FindWindowW(kWindowClass, kWindowTitle)) {
    ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
    ::SetForegroundWindow(hwnd);
  }
  ::CloseHandle(mutex);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (AnotherInstanceIsRunning(command_line)) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
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
  // Portrait by default; the layout is responsive and adapts when resized.
  Win32Window::Size size(440, 900);
  if (!window.Create(L"Weronity", origin, size)) {
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
