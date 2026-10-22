# Linux 实现与本机调试

Linux 桌面版纳入 1.0.0 源码与发布范围，0.9.6 及更早安装包不包含 Linux 程序；本次安装包与验证的实际状态见 [1.0.0 发布记录](releases/1.0.0.md)。目标系统为 **Ubuntu 24.04 LTS 同代或更新的桌面发行版（glibc 2.39+、GTK 3.24），x64 与 arm64**。发行形式为完整目录的 `tar.gz`，未签名；当前不提供 deb、rpm、Flatpak、Snap、AppImage 或软件商店版本，也不支持 32 位系统。

## 初始实现验证记录

以下为 2026-10-22 初始实现的验证记录，使用 Flutter 3.47.6 / Dart 3.13.5；后续审查修复的回归范围单独记录，不以初始构建代替修复后的验证：

- macOS 主机：`dart format` 检查无改动，`flutter analyze` 无问题，Flutter 全量 **1019 项**测试通过。
- Ubuntu 24.04 arm64 容器（原生）：以非 root 用户完整运行 `scripts/package-linux.sh` 通过。包括公共检查、Flutter 全量 **1019 项**测试，以及原生 CTest **8/8**（启用 AddressSanitizer / UndefinedBehaviorSanitizer，设置 `TAMAYURA_LINUX_TESTS_NO_SKIP=1`），覆盖存储、缩略图缓存、预览、设置、文案、发现核心、托盘 D-Bus 协议及 Avahi 注册浏览；工程注册与图标检查通过，桌面入口在含空格、引号、`$`、反引号和反斜杠的路径下通过 `desktop-file-validate` 并经 GLib 实际启动。Release 包的文件、版本、ELF 架构、glibc / libstdc++ 符号版本、库搜索路径、归档条目与构建机路径扫描均通过，解压后的应用以空白配置启动并加载包内 SQLite。
- Ubuntu 24.04 x64 容器（Apple 芯片上的 QEMU 用户态仿真，按 CI 的依赖清单安装）：在 `TAMAYURA_SANITIZE=OFF` 且未启动 avahi-daemon 的条件下完整运行 `scripts/package-linux.sh` 通过。Flutter 全量 **1019 项**测试通过，原生 CTest 7 项通过，Avahi 发现测试按设计跳过；x64 Release 构建、ELF（x86-64）与 glibc / libstdc++ 符号版本核验、归档与构建机路径扫描均通过，解压后的应用启动并加载包内 SQLite。仿真环境不支持 AddressSanitizer，Avahi 也识别不到网卡，x64 的 sanitizer 与发现测试由 CI 的 x64 runner 执行。
- 两个 arm64 容器通过 mDNS 自动发现、确认并同步相册：JPEG、带透明通道的 PNG、视频经系统缩略图程序均生成缩略图，随机数据显示占位；单流下载与 60 MiB 文件的四路并发下载完成后 SHA-256 与源文件一致，暂存分片按时清理；接收端本地原图预览正常。
- 没有文件管理器或默认应用时，「在文件夹中显示」「用其他应用打开」分别给出失败提示，不再误报成功；没有状态托盘时 Ctrl+Q 和窗口关闭请求均正常退出；Release 构建第二次启动会显示已运行窗口后立即退出。
初始实现阶段尚未验证：Linux CI 与 Tag 发布工作流的远端运行、x64 真实环境中的 sanitizer 与 Avahi 测试、真实 GNOME / KDE / Xfce 桌面与 Wayland 会话、真实托盘宿主交互、与 Android / macOS / Windows 真机互传、断网和睡眠恢复、HiDPI 与屏幕阅读器。容器内的回环与双容器测试不能替代真机验收。

## 审查修复与回归验证

2026-10-22 补充以下回归，均针对当前 Linux 源码，不涉及数据库或协议变更：

- `linux/tests/discovery_core_test.cc`：当前接口移除后切换到备用地址，备用接口反复失败不丢失有效设备，最后接口移除只发送一次 `lost`，恢复、重置、同地址双接口及地址 / 名称 / 端口更新的通知行为。Avahi 的移除、解析失败和无效记录更新共用此接口状态逻辑。
- `linux/tests/storage_test.cc`：合法的 3991 字节对端相对路径叠加接收层级后超限，在创建接收目录前失败；ASCII 与中文路径的 4095 / 4096 字节边界、文件名截短与同名后缀边界。匿名保存与独占创建均验证失败无新增文件、分片保留，以及成功结果可读取和删除；`app_text_test.cc` 核对三语言恢复提示。
- `test/transfer_test.dart`：原生返回 `PATH_TOO_LONG` 或权限错误时不登记下载完成、不删除分片；调整接收目录后复用完整分片离线重试，成功后才登记完成并清理暂存。

本次实际验证：Flutter 3.47.6 / Dart 3.13.5 下格式检查无改动、静态分析无问题，`flutter test --no-pub --coverage` 全量 **1020 项通过**。Ubuntu 24.04 arm64 临时容器以非 root 用户执行完整 `scripts/test-linux-native.sh`，启用 ASan / UBSan、启动 dbus 与 Avahi，并设置 `TAMAYURA_LINUX_TESTS_NO_SKIP=1`，原生 CTest **8/8 通过且无跳过**；工程注册、图标及桌面入口安装、GLib 实际启动和移除检查通过。镜像未安装 `desktop-file-validate`，该独立校验跳过。`git diff --check` 通过。

本次没有重新打包、运行 x64 原生测试或进行真实双网卡切换和跨设备验收；多接口覆盖来自原生状态测试，实际 Avahi 注册 / 浏览集成测试不能代替双网卡真机验收。

### 正式发布准备中的 C++17 编译修复

1.0.0 分支 CI 的 arm64 原生 9 项 CTest 与桌面入口检查通过后，Release 应用编译在 `lan_discovery.cc` 失败：失效地址处理 lambda 捕获了结构化绑定，Clang 将其识别为 C++20 扩展，而项目使用 C++17。改为普通局部变量副本后，保留解析记录移除前的键与接口槽位，不改变多接口失效处理。其余 Linux 结构化绑定均未被 lambda 捕获。

原生测试现在与 Flutter Linux Runner 一样使用 Clang，并明确将 `c++20-extensions` 诊断视为错误；已有 `linux_lan_discovery_test` 直接编译同一生产源文件，可在测试构建阶段发现该问题。本机以同一原生测试 CMake 编译选项验证了最小代码片段：普通局部副本编译并运行通过，恢复原结构化绑定捕获后编译按预期失败；`git diff --check` 通过。未在本机执行 Linux 原生全量测试或 Release 打包，仍须通过新提交的 Linux x64 与 arm64 CI；片段验证不能替代发行包验收。

## 功能与平台接入

- Flutter 复用相册、设备记忆、离线缩略图、渐进同步与断点恢复，沿用 gRPC v4、层级接收及超过 50 MiB 的四路并发下载。`LinuxBridge` 使用与 Windows / macOS 相同的进程内下载调度；设备 ID 形如 `linux-<UUID>`。
- `linux/runner/linux_platform.cc` 注册 `tamayura/platform`、`tamayura/updates` 方法通道和 `tamayura/discovery`、`tamayura/sharing` 事件通道。Flutter 的 Linux 消息接口只能在 GTK 主线程使用：扫描、缩略图、范围读取、保存与删除在固定线程池执行（每个硬件线程一个，无法取得时为 4），结果经 `MainDispatcher` 回到主线程，应用退出后丢弃迟到结果。
- 共享目录与接收目录使用 GTK 原生文件夹选择器（`GtkFileChooserNative`），只接受本地路径；GVfs 远程位置没有本地路径时提示改选本地文件夹。窗口隐藏时不打开选择器。
- 原生存储从 `/` 逐级用 `O_PATH | O_NOFOLLOW` 打开路径，后续操作都相对已固定的目录描述符进行，祖先目录被替换或改名也不会转向其他位置；记录每级目录的设备号与 inode，识别 bind mount 造成的同一目录别名。拒绝文件系统根目录、重复及父子重叠的共享目录；扫描跳过隐藏文件、符号链接、无法命名或打开的文件与子目录，只有共享根目录不可读时整次扫描失败。对端只看到不透明媒体 ID 与相对路径，单次读取上限为 2 MiB（与 Dart `mediaReadChunkBytes` 一致）。
- 保存时用 `O_TMPFILE` 在接收目录内写入匿名文件，按顺序拷贝私有分片（优先 `copy_file_range`），校验总大小并 `fsync` 后再链接为最终名称，同名时追加 ` (n)` 序号，不覆盖已有文件；文件系统不支持 `O_TMPFILE` 时改为独占新建最终名称，失败时删除该文件。名称按 Linux 单个文件名 255 字节限制截短并保留扩展名。创建接收子目录前检查接收根、设备名、合集名、相对目录与文件名组成的完整绝对路径，最多 4095 个 UTF-8 字节（为 `PATH_MAX` 的结尾 NUL 留出一字节）；每个重名候选再次检查。超限返回 `PATH_TOO_LONG` 和三语言提示，不登记为已保存，分片保留供调整接收路径后重试。容量用 `fstatvfs` 查询，同卷判断基于设备号。
- 预览与缩略图使用 GdkPixbuf，但只按内容识别 JPEG、PNG、GIF、BMP、TIFF、WebP，以及系统已安装对应解码器时的 HEIF / AVIF；图标、矢量和旧格式解码器不会接触媒体文件。解码前按像素预算拒绝超大图片，应用 EXIF 方向；DNG、CR2、NEF、ARW 等 TIFF 结构的 RAW 只读取内嵌 JPEG 预览，不解码传感器数据。来源端为自己共享的视频等文件优先读取 freedesktop 缩略图缓存，再调用系统已安装的 `*.thumbnailer`（例如 ffmpegthumbnailer），单次限时 20 秒，退出应用时 100 毫秒内停止；收到的文件只在进程内解码。无法解码时显示占位，不阻塞其他条目同步。
- 自动发现通过 Avahi 客户端在本地链路注册与浏览 `_tamayura._tcp`，TXT 键与其他平台一致。按网络接口与协议分别保存解析结果，保持当前有效地址，当前接口移除或解析失败时选择仍可用的接口并发送地址更新；没有有效接口时才发送设备丢失事件。重复解析相同结果不重复通知。avahi-daemon 未运行时只报告一次错误，手动输入 IP 或由其他设备扫描本机二维码仍可连接；守护进程启动后自动恢复发现。设备名优先使用 `/etc/machine-info` 的友好主机名，否则使用主机名。
- 已下载文件可「在文件夹中显示」：先调用文件管理器的 `org.freedesktop.FileManager1.ShowItems` 选中文件，不支持时打开所在文件夹；「用其他应用打开」和视频播放通过 GIO 交给默认应用。没有可用处理程序时返回错误并在界面提示，不报告虚假成功。保留本机连接二维码供 Android / Mac 扫码；当前扫码插件没有 Linux 实现，因此不显示相机扫码入口。
- 侧栏、窗口缩放与 Ctrl 快捷键同 Windows：`Ctrl+1/2/3` 切换页面，`Ctrl+,` 打开设置，`Ctrl+R` 刷新；`Ctrl+Q` 由 GTK 应用动作直接退出，也适用于没有托盘的桌面。
- 应用内「检查更新」与 macOS 相同，确认后只打开官方 Release 页面，由用户下载并替换完整目录；原生层只接受官方仓库具体版本的 HTTPS 页面地址。
- Flutter 的 Linux 引擎直接读取字体文件，不经 fontconfig 回退，未指定的中日文字形会显示为方框。`AppTheme.forLocale` 在 Linux 依次指定常见拉丁字体、按界面语言排序的中文 / 日文字体（Noto Sans CJK、思源黑体、文泉驿、IPA 等）和 Noto Color Emoji；系统未安装任何中日文字体时仍无法显示，需安装发行版的 Noto CJK 字体包。

## 窗口、托盘与单实例

托盘使用 StatusNotifierItem 加 `com.canonical.dbusmenu`，直接在会话总线导出，不依赖 libappindicator。KDE Plasma、Ubuntu 默认桌面（AppIndicator 扩展）、Xfce、Cinnamon、MATE、Budgie 及多数 Wayland 状态栏可显示；原版 GNOME 需自行安装 AppIndicator 扩展。只有 `org.kde.StatusNotifierWatcher` 接受图标且报告存在宿主时托盘才算可用：此时关闭窗口只隐藏窗口，引擎、页面状态与下载继续；单击图标或菜单「打开玉响」恢复窗口（Wayland 下使用宿主提供的 xdg-activation 令牌聚焦），「退出玉响」真正退出。没有托盘时关闭窗口按常规退出；托盘在窗口隐藏期间消失会主动重新显示窗口，避免无法找回。详见 [桌面托盘与窗口生命周期](桌面托盘与窗口生命周期.md)。

退出、Ctrl+Q 和托盘退出都经过同一窗口关闭请求，Flutter 的退出流程仍会执行。Release 构建以 `dev.tamayura.app` 注册 GtkApplication，同一用户会话只运行一个实例：再次启动会显示已有窗口后退出，避免两个进程争用数据库、设备身份与服务端口。Debug 构建不限制单实例，便于 `flutter run` 与已安装的 Release 并存。

「后台共享」保存在本机设置中，默认关闭。开启后隐藏到托盘时继续提供文件；关闭时隐藏窗口会停止 gRPC 监听、设备发现和相册同步。已开始的接收下载在进程存活期间继续。应用不添加开机自启、后台系统服务或阻止睡眠，退出与系统睡眠都会中断传输。

## 数据位置

| 内容 | 位置 |
| --- | --- |
| 媒体元数据库、下载任务库 | `$XDG_DATA_HOME/tamayura/databases`（默认 `~/.local/share/tamayura/databases`） |
| 未完成下载分片 | `$XDG_DATA_HOME/tamayura/transfers` |
| 预览临时文件 | `$XDG_CACHE_HOME/tamayura/media`（默认 `~/.cache/tamayura/media`） |
| 系统缩略图程序输出 | `$XDG_CACHE_HOME/tamayura/thumbnailer` |
| 设备身份与后台共享设置 | `$XDG_CONFIG_HOME/tamayura/settings.ini`（默认 `~/.config/tamayura`） |

私有目录以 `0700` 创建。设备身份不在数据目录内，清空数据库或缓存后仍保持同一设备 ID；删除 `settings.ini` 会生成新身份，其他设备会将其视为新设备。移动或替换程序目录不改变这些位置。外部共享目录和接收目录中的文件不属于应用数据。

SQLite 由 `sqlite3` 包的原生资产随应用打包（`lib/libsqlite3.so`），不依赖系统是否安装开发包。Flutter 测试会在 `build/native_assets/linux/native_assets.json` 写入构建机绝对路径，CMake 安装时排除该测试清单；正式程序使用 `data/flutter_assets/NativeAssetsManifest.json` 按名称加载包内 SQLite。

## 准备 Linux 开发环境

1. 安装 Git、Flutter **3.47.6**（随附 Dart **3.13.5**）。Flutter 官方 Linux 压缩包只提供 x64，arm64 主机可检出 `3.47.6` 标签：

   ```sh
   git clone --depth 1 --branch 3.47.6 https://github.com/flutter/flutter.git
   ```

2. Ubuntu 24.04 安装构建与测试依赖：

   ```sh
   sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-14-dev libavahi-client-dev avahi-daemon desktop-file-utils libglib2.0-bin xvfb xauth fonts-noto-cjk
   ```

   运行发行包只需要系统已有的 GTK 3、Avahi 客户端库与 C++ 运行库；桌面发行版通常已安装。自动发现另需运行 avahi-daemon。视频缩略图需要系统安装缩略图程序，例如 `ffmpegthumbnailer`。

3. 在项目根目录检查环境并运行：

   ```sh
   flutter --version
   flutter doctor -v
   flutter pub get
   flutter run -d linux
   ```

开启防火墙时，仅在可信局域网允许 gRPC TCP 端口（默认 `50728`，占用时以「设备」页显示的端口为准）以及 mDNS UDP `5353`。不要为排查问题关闭整机防火墙；手动 IP 连接正常而自动发现失败时，优先检查 avahi-daemon、组播和网络隔离。

## 检查、构建与打包

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
scripts/test-linux-native.sh
```

`scripts/test-linux-native.sh` 用 CMake 配置 `linux/tests`（有 Ninja 时使用 Ninja），使用与 Flutter Runner 相同的 Clang / C++17，并以 `-Werror=c++20-extensions` 拒绝误用更高标准的语法。已有 GCC 构建缓存须改用新的构建目录，或重新配置为 `-DCMAKE_CXX_COMPILER=clang++`。默认启用 AddressSanitizer / UndefinedBehaviorSanitizer，构建后执行 CTest；缺少测试或测试失败会报错。缺少 dbus-daemon 或 avahi-daemon 时托盘与发现测试会跳过，设置 `TAMAYURA_LINUX_TESTS_NO_SKIP=1`（CI 默认设置）则视为失败。主机缺少 sanitizer 运行库时可设 `TAMAYURA_SANITIZE=OFF`。在 QEMU 用户态仿真（例如 Apple 芯片上的 x64 容器）中，AddressSanitizer 无法运行，avahi-daemon 也识别不到网卡，连 `avahi-browse` 都找不到本机发布的服务；此类环境只能关闭 sanitizer 并让发现测试跳过，对应覆盖以该架构的真机或 CI 为准。脚本还核对 Runner 源文件与测试均已注册、应用 ID 和九种尺寸图标一致，并在临时目录验证桌面入口的安装、启动、拒绝含 `%` 路径和移除。

完整发行包执行：

```sh
scripts/package-linux.sh
```

脚本只在 Linux 运行，按主机架构生成 `dist/<version>/Tamayura-<version>-linux-x64.tar.gz` 或 `-linux-arm64.tar.gz`，以及独立的 `SHA256SUMS-linux-<arch>`，版本取自 `pubspec.yaml`。流程如下：

1. 核对 Flutter 3.47.6 / Dart 3.13.5，把检出中的已跟踪及未忽略文件复制到临时目录，再在该目录执行依赖解析、格式、静态分析、全部 Flutter 测试、原生测试与 Release 构建。Flutter 会把插件注册文件的绝对路径写入 AOT 快照，从中性临时目录构建可避免发行包包含个人目录；全新构建目录也避免混入 debug 构建残留的 `kernel_blob.bin`。
2. 核对包内必需文件、可执行权限、`version.json` 版本与构建号、包内 SQLite 清单、九种尺寸图标；拒绝符号链接、测试清单和 debug 快照；所有 ELF 必须是对应架构的 64 位文件，glibc / libstdc++ 符号版本不超过 Ubuntu 24.04（GLIBC 2.39、GLIBCXX 3.4.33、CXXABI 1.3.15），库搜索路径只能位于包内，且 `ldd` 无缺失依赖。
3. 以固定归属、权限和源码提交时间生成 tar.gz，再解压核对只有一个顶层目录、条目只含普通文件与目录、文件列表、内容和可执行权限与构建结果一致，并扫描检出路径与主目录等构建机路径。临时目录位于主目录内时会被拒绝，可改用 `TMPDIR=/tmp`。
4. 有 `xvfb-run` 与 `dbus-run-session` 时，以空白临时配置启动解压后的应用，确认进程实际加载包内的 `lib/libsqlite3.so` 后结束；缺少时明确输出 SKIP。

`.github/workflows/linux.yml` 在 `ubuntu-24.04`（x64）和 `ubuntu-24.04-arm`（arm64）上执行同一脚本并保存包与校验文件；Tag 发布工作流同样执行两个架构并加入 Release，详见 [发布与打包](发布.md)。只有实际工作流成功才能记为 CI 验证通过。

## 安装与桌面入口

接收者完整解压 tar.gz，在解压目录中运行 `./tamayura`。不要只复制可执行文件：`lib/` 中的 Flutter 引擎、AOT 程序与 SQLite，以及 `data/` 中的资源都必须保留在同一目录。

```sh
tar -xzf Tamayura-<version>-linux-x64.tar.gz
cd Tamayura-<version>-linux-x64
./install-desktop-entry.sh
```

`install-desktop-entry.sh` 只写入当前用户的 `$XDG_DATA_HOME/applications/dev.tamayura.app.desktop` 与 hicolor 图标，`Exec` / `TryExec` 指向当前解压目录并按 Desktop Entry 规则转义；不需要 root，也不修改系统目录。移动或更新到新目录后在新目录重新运行；`--remove` 删除入口与图标。GLib 在展开 `%%` 前检查程序路径，路径含 `%` 的入口会被桌面隐藏，Desktop Entry 也不能包含换行，因此脚本拒绝这两类路径并保留原有入口，提示信息跟随系统语言显示中文、日文或英文。

更新时先退出玉响，解压新版本，在新目录运行 `install-desktop-entry.sh`，确认正常后删除旧目录。用户数据位于上表的 XDG 目录，不随程序目录删除。

## 源码结构

| 文件 | 职责 |
| --- | --- |
| `linux/runner/my_application.cc` | GtkApplication、单实例、窗口与图标、关闭到托盘、Ctrl+Q |
| `linux/runner/linux_platform.cc` | 平台通道、文件夹选择器、打开与定位文件、更新页面 |
| `linux/runner/storage_core.cc` | 安全路径、目录扫描与共享目录目录册、范围读取、保存、删除、容量 |
| `linux/runner/media_preview.cc` | 格式识别、GdkPixbuf 解码、EXIF 方向、RAW 内嵌预览、系统缩略图 |
| `linux/runner/lan_discovery.cc`、`discovery_core.cc` | Avahi 注册与浏览、设备名、TXT 校验 |
| `linux/runner/desktop_tray.cc` | StatusNotifierItem 与 dbusmenu |
| `linux/runner/settings_store.cc` | `settings.ini` 中的设备身份与后台共享 |
| `linux/runner/app_text.cc` | 原生界面、错误与托盘的三语言文案 |
| `linux/runner/main_dispatcher.cc` | 工作线程池与回到 GTK 主线程的投递 |
| `linux/packaging/install-desktop-entry.sh` | 当前用户的应用菜单入口 |
| `linux/tests/` | 原生 CTest |
| `lib/platform/linux_bridge.dart` | Dart 侧平台桥接 |

## Linux 验收清单

- [x] 容器内 arm64 完整打包、原生测试、双容器发现 / 同步 / 下载、失败提示、无托盘退出、单实例与桌面入口检查通过（见初始实现验证记录；不代表后续修复已重新打包）。
- [ ] 在 Ubuntu 24.04 x64 与 arm64 真机或虚拟机上从完整 tar.gz 启动，显示正确版本，窗口缩放、浅色 / 深色、中日英界面与字体、Ctrl 快捷键正常。
- [ ] GNOME（Ubuntu AppIndicator 与原版无托盘）、KDE Plasma 的 X11 与 Wayland 会话下关闭、恢复、托盘菜单与退出符合说明；桌面入口显示正确名称和图标。
- [ ] 文件夹选择器选择与取消、中文 / 日文 / 空格路径、多个共享根、父子目录拒绝、符号链接与失效目录处理正常。
- [ ] Linux ↔ Android 16+ / macOS 15+ / Windows 双向自动发现、手动 IP、二维码连接、记住设备与离线预览正常。
- [ ] 常见照片、HEIC（安装解码器时）、RAW 与视频缩略图正常，损坏或不支持的媒体显示占位。
- [ ] 小文件与超过 50 MiB 文件下载后大小和 SHA-256 一致；同名不覆盖；文件管理器定位、默认应用打开正常。
- [ ] 下载取消、重试、断网、对端退出、睡眠唤醒与重启后续传正常；后台共享开 / 关行为符合设置。

调试时可保存完整日志：

```sh
flutter run -d linux -v 2>&1 | tee linux-debug.log
```

日志可能包含本地路径和局域网地址，提交问题前先移除不希望公开的内容。遇到数据库版本不兼容时保留上述数据目录并报告问题，按 [兼容与升级](兼容与升级.md) 处理；不能将删除数据目录作为正式版常规升级步骤。

平台依据：[Flutter Linux 开发环境](https://docs.flutter.dev/platform-integration/linux/setup)、[Desktop Entry 规范](https://specifications.freedesktop.org/desktop-entry-spec/latest/)、[StatusNotifierItem](https://www.freedesktop.org/wiki/Specifications/StatusNotifierItem/)、[Avahi 客户端 API](https://avahi.org/doxygen/html/)、[freedesktop 缩略图规范](https://specifications.freedesktop.org/thumbnail-spec/latest/)。
