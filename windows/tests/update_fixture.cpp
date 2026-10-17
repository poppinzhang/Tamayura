#include <windows.h>

#include <cwchar>

int wmain(int argument_count, wchar_t** arguments) {
  if (argument_count > 1 && std::wcscmp(arguments[1], L"--wait") == 0) {
    Sleep(60000);
  }
  return 0;
}
