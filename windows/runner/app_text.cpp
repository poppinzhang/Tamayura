#include "app_text.h"

#include <array>
#include <cwchar>
#include <mutex>

namespace tamayura {
namespace app_text {
namespace {

constexpr size_t kTextCount = static_cast<size_t>(TextId::kOperationFailed) + 1;
using Table = std::array<const wchar_t*, kTextCount>;

const Table kChinese = {
    L"玉响 Tamayura",
    L"打开玉响",
    L"退出玉响",
    L"选择要共享或接收媒体文件的目录",
    L"局域网发现失败，请检查专用网络、防火墙与 DNS Client 服务；也可使用手动连接",
    L"无效的设备 ID 或服务端口",
    L"无法创建 Windows DNS-SD 服务",
    L"无法读取 Windows 网络接口",
    L"缺少参数：",
    L"缺少共享状态",
    L"无效的服务端口",
    L"不支持的界面语言",
    L"无法保存 Windows 应用设置",
    L"无法创建 Windows 设备标识",
    L"无法读取 Windows 设备标识",
    L"无法启动或唤回玉响。如果玉响正在启动或退出，请稍后重试；如果已运行，请从托盘打开，并确认两次启动使用相同的用户和权限。",
    L"Windows 操作失败",
};

const Table kJapanese = {
    L"Tamayura",
    L"Tamayura を開く",
    L"Tamayura を終了",
    L"メディアファイルを共有または受信するフォルダーを選んでください",
    L"ローカルネットワークの検出に失敗しました。プライベートネットワーク、ファイアウォール、DNS Client サービスを確認するか、手動で接続してください",
    L"デバイス ID またはサービスのポートが無効です",
    L"Windows の DNS-SD サービスを作成できません",
    L"Windows のネットワークインターフェイスを読み込めません",
    L"引数がありません: ",
    L"共有の状態がありません",
    L"サービスのポートが無効です",
    L"対応していない表示言語です",
    L"Windows のアプリ設定を保存できません",
    L"Windows のデバイス識別子を作成できません",
    L"Windows のデバイス識別子を読み込めません",
    L"Tamayura を起動または再表示できません。起動中または終了中の場合は、しばらくしてから再試行してください。実行中の場合はトレイから開き、同じユーザーと権限で起動していることを確認してください。",
    L"Windows の操作に失敗しました",
};

const Table kEnglish = {
    L"Tamayura",
    L"Open Tamayura",
    L"Exit Tamayura",
    L"Choose a folder to share media from or receive media into",
    L"Local network discovery failed. Check the private network, firewall and DNS Client service, or connect manually.",
    L"Invalid device ID or service port",
    L"Can't create the Windows DNS-SD service",
    L"Can't read the Windows network interfaces",
    L"Missing argument: ",
    L"Missing sharing state",
    L"Invalid service port",
    L"Unsupported interface language",
    L"Can't save the Windows app settings",
    L"Can't create the Windows device identifier",
    L"Can't read the Windows device identifier",
    L"Can't start or reopen Tamayura. If it is starting or exiting, try again shortly. If it is already running, open it from the tray and check that both launches use the same user and privileges.",
    L"The Windows operation failed",
};

std::mutex preference_mutex;
std::string preference = "system";

bool Supported(const std::string& code) {
  return code == "zh" || code == "ja" || code == "en";
}

std::vector<std::wstring> PreferredUiLanguages() {
  ULONG count = 0, size = 0;
  if (!GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, nullptr, &size) ||
      size == 0) {
    return {};
  }
  std::wstring buffer(size, L'\0');
  if (!GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, buffer.data(),
                                   &size)) {
    return {};
  }
  // The result is a double-null-terminated list of language names.
  std::vector<std::wstring> languages;
  for (const wchar_t* item = buffer.c_str(); *item != L'\0';
       item += std::wcslen(item) + 1) {
    languages.emplace_back(item);
  }
  return languages;
}

}  // namespace

std::string Resolve(const std::string& value,
                    const std::vector<std::wstring>& preferred) {
  if (Supported(value)) return value;
  for (const auto& tag : preferred) {
    std::string code;
    for (wchar_t character : tag) {
      if (character == L'-' || character == L'_') break;
      if (character >= L'A' && character <= L'Z') {
        character = static_cast<wchar_t>(character - L'A' + L'a');
      }
      if (character < L'a' || character > L'z') {
        code.clear();
        break;
      }
      code.push_back(static_cast<char>(character));
    }
    if (Supported(code)) return code;
  }
  return "en";
}

bool SetPreference(const std::string& value) {
  if (value != "system" && !Supported(value)) return false;
  std::lock_guard<std::mutex> lock(preference_mutex);
  preference = value;
  return true;
}

std::string Preference() {
  std::lock_guard<std::mutex> lock(preference_mutex);
  return preference;
}

std::string Current() { return Resolve(Preference(), PreferredUiLanguages()); }

const wchar_t* Text(TextId id, const std::string& language) {
  const Table& table = language == "zh"   ? kChinese
                       : language == "ja" ? kJapanese
                                          : kEnglish;
  return table[static_cast<size_t>(id)];
}

const wchar_t* Text(TextId id) { return Text(id, Current()); }

std::string Utf8(TextId id) {
  const wchar_t* text = Text(id);
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string value(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, value.data(), size, nullptr,
                      nullptr);
  return value;
}

}  // namespace app_text
}  // namespace tamayura
