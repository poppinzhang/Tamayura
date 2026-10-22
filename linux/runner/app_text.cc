#include "app_text.h"

#include <glib.h>

#include <cstddef>
#include <mutex>

namespace tamayura {
namespace app_text {
namespace {

struct Entry {
  const char* zh;
  const char* ja;
  const char* en;
};

// Ordered as TextId.
constexpr Entry kTable[] = {
    {"玉响", "Tamayura", "Tamayura"},
    {"玉响 · 关闭窗口后继续在后台运行",
     "Tamayura · ウィンドウを閉じてもバックグラウンドで動作します",
     "Tamayura · Keeps running in the background after the window closes"},
    {"打开玉响", "Tamayura を開く", "Open Tamayura"},
    {"退出玉响", "Tamayura を終了", "Quit Tamayura"},
    {"选择要共享或接收媒体文件的目录",
     "メディアファイルを共有または受信するフォルダーを選んでください",
     "Choose a folder to share media from or receive media into"},
    {"选择", "選択", "Select"},
    {"取消", "キャンセル", "Cancel"},
    {"缺少参数：%s", "引数がありません: %s", "Missing argument: %s"},
    {"缺少共享状态", "共有の状態がありません", "Missing sharing state"},
    {"无效的服务端口", "サービスのポートが無効です", "Invalid service port"},
    {"不支持的界面语言", "対応していない表示言語です",
     "Unsupported interface language"},
    {"无效的设备 ID 或服务端口", "デバイス ID またはサービスのポートが無効です",
     "Invalid device ID or service port"},
    {"局域网发现失败，请确认 Avahi（avahi-daemon）正在运行，且防火墙允许 mDNS"
     "（UDP 5353）；也可使用手动连接",
     "ローカルネットワークの検出に失敗しました。Avahi（avahi-daemon）が動作して"
     "いること、ファイアウォールで mDNS（UDP 5353）が許可されていることを確認する"
     "か、手動で接続してください",
     "Local network discovery failed. Make sure Avahi (avahi-daemon) is running "
     "and the firewall allows mDNS (UDP 5353), or connect manually."},
    {"无法读取网络接口", "ネットワークインターフェイスを読み込めません",
     "Can't read the network interfaces"},
    {"无法保存玉响设置，请检查配置目录权限",
     "Tamayura の設定を保存できません。設定フォルダーの権限を確認してください",
     "Can't save the Tamayura settings. Check the configuration folder "
     "permissions."},
    {"无法创建或读取设备标识", "デバイス識別子を作成または読み込みできません",
     "Can't create or read the device identifier"},
    {"操作失败，请重试", "操作に失敗しました。もう一度お試しください",
     "The operation failed. Try again."},
    {"请先打开应用窗口", "先にアプリのウィンドウを開いてください",
     "Open the app window first"},
    {"目录选择器已打开", "フォルダーの選択画面はすでに開いています",
     "The folder picker is already open"},
    {"请选择这台电脑上的文件夹", "このコンピューターのフォルダーを選んでください",
     "Choose a folder on this computer"},
    {"不能共享整个文件系统，请选择具体的文件夹",
     "ファイルシステム全体は共有できません。フォルダーを選んでください",
     "The whole file system can't be shared. Choose a specific folder."},
    {"无法访问文件或目录，请检查权限和路径",
     "ファイルまたはフォルダーにアクセスできません。権限とパスを確認してください",
     "Can't access the file or folder. Check permissions and the path."},
    {"不支持符号链接，请选择普通文件夹",
     "シンボリックリンクには対応していません。通常のフォルダーを選んでください",
     "Symbolic links aren't supported. Choose a regular folder."},
    {"需要本机绝对路径", "このデバイスの絶対パスが必要です",
     "A local absolute path is required"},
    {"媒体目录或文件名称无效", "メディアのフォルダー名またはファイル名が無効です",
     "Invalid media folder or file name"},
    {"媒体相对路径无效", "メディアの相対パスが無効です",
     "Invalid media relative path"},
    {"媒体相对路径不能使用盘符", "メディアの相対パスにドライブ文字は使えません",
     "Media relative paths can't use drive letters"},
    {"无法创建接收子目录", "保存先のサブフォルダーを作成できません",
     "Can't create the download subfolder"},
    {"文件路径为空", "ファイルのパスが空です", "The file path is empty"},
    {"无法读取待删除的本地文件", "削除するローカルファイルを読み込めません",
     "Can't read the local file to delete"},
    {"只能处理本地普通文件", "扱えるのはローカルの通常ファイルのみです",
     "Only regular local files are supported"},
    {"无法删除本地文件，请检查目录权限",
     "ローカルファイルを削除できません。フォルダーの権限を確認してください",
     "Can't delete the local file. Check folder permissions."},
    {"无法读取媒体文件信息", "メディアファイルの情報を読み込めません",
     "Can't read the media file information"},
    {"媒体文件不存在或不是普通文件",
     "メディアファイルが存在しないか、通常ファイルではありません",
     "The media file doesn't exist or isn't a regular file"},
    {"媒体文件过大", "メディアファイルが大きすぎます",
     "The media file is too large"},
    {"无效的文件分块范围，单次最多 2 MiB",
     "ファイルの分割範囲が無効です（1 回あたり最大 2 MiB）",
     "Invalid file chunk range; each chunk is at most 2 MiB"},
    {"文件已改变，请刷新相册", "ファイルが変更されました。アルバムを更新してください",
     "The file changed. Refresh the album."},
    {"文件提前结束，请刷新相册",
     "ファイルが途中で終わっています。アルバムを更新してください",
     "The file ended early. Refresh the album."},
    {"共享目录已改变，请重新扫描",
     "共有フォルダーが変更されました。もう一度スキャンしてください",
     "Shared folders changed. Scan again."},
    {"共享目录不能重复或互相包含",
     "共有フォルダーは重複したり、互いに含んだりできません",
     "Shared folders can't repeat or contain each other"},
    {"共享目录标识重复", "共有フォルダーの識別子が重複しています",
     "Shared folder identifiers are duplicated"},
    {"无法读取共享目录", "共有フォルダーを読み込めません",
     "Can't read the shared folder"},
    {"文件未被共享，请刷新相册",
     "ファイルは共有されていません。アルバムを更新してください",
     "The file isn't shared. Refresh the album."},
    {"下载分片或大小无效", "ダウンロードの分割データまたはサイズが無効です",
     "Invalid download parts or size"},
    {"下载源文件必须在应用私有目录中",
     "ダウンロード元のファイルはアプリのプライベートフォルダーにある必要があります",
     "Download source files must be in the app's private folder"},
    {"下载分片大小与预期不符",
     "ダウンロードの分割データのサイズが想定と一致しません",
     "The download parts don't match the expected size"},
    {"无法创建接收文件", "保存先のファイルを作成できません",
     "Can't create the download file"},
    {"接收文件的完整路径过长，请选择路径更短的接收目录，或缩短目录名称后重试",
     "保存先ファイルのパスが長すぎます。パスが短い保存先を選ぶか、フォルダー名を"
     "短くしてからもう一度お試しください",
     "The full download path is too long. Choose a shorter destination path "
     "or shorten folder names, then try again."},
    {"无法读取下载暂存文件", "ダウンロードの一時ファイルを読み込めません",
     "Can't read the staged download file"},
    {"下载分片在保存时已变化", "保存中にダウンロードの分割データが変わりました",
     "The download parts changed while saving"},
    {"无法保存下载文件，可能磁盘空间不足",
     "ダウンロードしたファイルを保存できません。ディスクの空き容量が不足している"
     "可能性があります",
     "Can't save the downloaded file. The disk may be full."},
    {"无法完成文件保存", "ファイルの保存を完了できません",
     "Can't finish saving the file"},
    {"同名文件过多，请整理接收目录",
     "同じ名前のファイルが多すぎます。保存先フォルダーを整理してください",
     "Too many files have the same name. Tidy the download folder."},
    {"无法准备应用数据目录，请检查主目录权限和剩余空间",
     "アプリのデータフォルダーを準備できません。ホームフォルダーの権限と空き容量を"
     "確認してください",
     "Can't prepare the app data folder. Check home folder permissions and "
     "free space."},
    {"只能打开受支持的媒体文件", "対応しているメディアファイルのみ開けます",
     "Only supported media files can be opened"},
    {"无法用默认应用打开媒体文件，请检查是否已安装对应的应用",
     "既定のアプリでメディアファイルを開けません。対応するアプリがインストール"
     "されているか確認してください",
     "Can't open the media file with the default app. Check that a suitable "
     "app is installed."},
    {"无法在文件管理器中显示文件", "ファイルマネージャーでファイルを表示できません",
     "Can't show the file in the file manager"},
    {"预览尺寸必须在 1 至 2560 之间",
     "プレビューのサイズは 1–2560 で指定してください",
     "The preview size must be from 1 to 2560"},
    {"无法解码此媒体文件", "このメディアファイルをデコードできません",
     "Can't decode this media file"},
    {"无法编码预览", "プレビューをエンコードできません",
     "Can't encode the preview"},
    {"缩略图生成超时", "サムネイルの作成がタイムアウトしました",
     "Creating the thumbnail timed out"},
    {"系统资源暂时不足，请稍后重试",
     "システムのリソースが一時的に不足しています。しばらくしてからもう一度お試し"
     "ください",
     "System resources are temporarily exhausted. Try again later."},
    {"更新页面地址无效", "アップデートページのアドレスが無効です",
     "The update page address is invalid"},
    {"无法打开更新页面，请检查默认浏览器后重试",
     "アップデートページを開けません。既定のブラウザーを確認して、もう一度お試し"
     "ください",
     "Can't open the update page. Check your default browser and try again."},
};

static_assert(sizeof(kTable) / sizeof(kTable[0]) ==
                  static_cast<std::size_t>(TextId::kCount),
              "Every TextId needs one table entry");

std::mutex preference_mutex;
std::string preference = "system";

bool Supported(const std::string& code) {
  return code == "zh" || code == "ja" || code == "en";
}

}  // namespace

std::string Resolve(const std::string& value,
                    const std::vector<std::string>& preferred) {
  if (Supported(value)) return value;
  for (const auto& tag : preferred) {
    // POSIX locale names look like ll_CC.codeset@modifier.
    std::string code;
    for (char character : tag) {
      if (character == '_' || character == '-' || character == '.' ||
          character == '@') {
        break;
      }
      if (character >= 'A' && character <= 'Z') {
        character = static_cast<char>(character - 'A' + 'a');
      }
      if (character < 'a' || character > 'z') {
        code.clear();
        break;
      }
      code.push_back(character);
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

std::vector<std::string> PreferredLanguages() {
  std::vector<std::string> languages;
  for (const gchar* const* name = g_get_language_names(); name && *name;
       ++name) {
    languages.emplace_back(*name);
  }
  return languages;
}

std::string Current() { return Resolve(Preference(), PreferredLanguages()); }

const char* Text(TextId id, const std::string& language) {
  const auto index = static_cast<std::size_t>(id);
  if (index >= static_cast<std::size_t>(TextId::kCount)) return "";
  const Entry& entry = kTable[index];
  return language == "zh" ? entry.zh : language == "ja" ? entry.ja : entry.en;
}

const char* Text(TextId id) { return Text(id, Current()); }

std::string Format(TextId id, const std::string& argument) {
  std::string text = Text(id);
  const auto placeholder = text.find("%s");
  if (placeholder != std::string::npos) text.replace(placeholder, 2, argument);
  return text;
}

}  // namespace app_text
}  // namespace tamayura
