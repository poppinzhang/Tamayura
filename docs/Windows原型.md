# Windows 实现与本机调试

Windows 与 Android、macOS 统一使用 `0.5.0+8`，变更记录在 `CHANGELOG.md` 的 `0.5.0`。已完成 Windows x64 可执行 ZIP 构建与核验；源码交接包仅作辅助构建输入。目标系统为 **Windows 10 1809（build 17763）及以上、Windows 11，x64**。当前不提供 Windows ARM64、32 位或 MSIX 安装包。

Windows 构建必须在 Windows 主机执行。本次 Windows x64 构建与测试已通过，发布记录仅保留通用工具链要求和脱敏结果；GUI、自动发现和真实设备互传验收仍需分别执行，不能由编译或单元测试代替。最终产物状态与实际验收范围见 [0.5.0 发布记录](releases/0.5.0.md)。

## 本次验证记录

2026-10-17使用正式 Flutter 3.47.6 / Dart 3.13.5：`dart format` 检查 64 个 Dart 文件无改动，`flutter analyze` 无问题，Flutter 全量 **370 项测试分别在 macOS 与 Windows 通过**；Windows 源码交接白名单 **4 项 Python 测试通过**。本次修正了测试临时路径拼接和 Android worker 平台 mock 初始化的跨平台假设，修正后两端全量测试通过，业务断言保持不变。

Windows 原生 CTest 已 **2/2 通过**：`discovery_core_test` 与 `windows_storage_test`，后者包含 **17 组存储测试**，使用真实 WIC、文件读写与目录联接边界。发现核心测试覆盖 ID、局域网 IPv4 和 UTF-8 等纯逻辑，不执行 Windows DNS API；实际 DNS-SD、GUI、跨设备传输及远端 CI 仍需单独验收。

最终 ZIP 已验证 13 个文件完整解压并与 Release 逐文件 SHA-256 一致，EXE 版本为 `0.5.0.8`。解压后的 EXE 在隔离应用数据下启动，由真实本机 gRPC 返回有效设备身份、协议 3 和空目录分页；系统 PATH 和其它工作目录下确认 SQLite 从解压包加载，检查后关闭本次进程并恢复原状态。这是进程与服务启动冒烟，不计作远程桌面 GUI 或跨设备验收。

## 功能与平台接入

- Flutter 复用相册、设备记忆、离线缩略图、渐进同步和相册断点恢复；沿用当前 gRPC v3、层级接收与超过 50 MiB 的四路并发下载，不新增跨版本兼容逻辑。
- Win32 系统文件夹选择器选择共享目录和接收目录；原生存储层递归扫描媒体、读取文件范围、生成预览并保存接收文件。Windows 文件名校验、父子目录重叠、路径穿越和重解析点等边界由原生层处理。媒体缩略图依赖系统的媒体处理能力，无法解码时允许占位并继续尝试原文件下载。
- 仅支持本机盘符下的普通目录与文件，不支持 UNC/网络路径、符号链接、目录联接或其它重解析点，包含 OneDrive 等云盘的占位文件/目录；请将媒体复制到普通本地目录后共享。图片预览使用 WIC，视频与部分图片格式使用 Windows Shell 缩略图提供者；HEIC、RAW、视频等能否预览取决于系统已安装的解码器，不能保证所有扩展名都有缩略图。
- 自动发现调用 Windows 的 `DnsServiceRegister`、`DnsServiceBrowse` 与 `DnsServiceResolve`，使用 `_tamayura._tcp.local`，无需安装 Bonjour。连接后仍由 gRPC 校验设备身份；手动连接仅接受局域网 IPv4。设备身份在本机持久保存，名称使用 Windows 设备名。
- Windows SQLite 使用 `sqflite_common_ffi`；`sqlite3` 的 Windows 原生资产随 Flutter 构建输出打包，数据库不依赖另行手动安装 SQLite。目录、媒体缓存和下载任务与现有桌面控制器共用。
- 桌面侧栏、可调整窗口及 Ctrl 快捷键：`Ctrl+1/2/3` 切换相册/设备/设置，`Ctrl+,` 打开设置，`Ctrl+R` 刷新。已下载文件可通过默认应用打开，或在资源管理器中定位；当前未接入 Windows 系统分享面板。
- 保留本机连接二维码，Android 或 Mac 可扫码连接这台 Windows；Windows 不显示相机扫码入口，因为当前扫码插件没有 Windows 实现。Windows 可用自动发现或手动输入对端 `IP:端口`。
- 下载由应用进程执行，窗口失去焦点或最小化后可继续。开启「后台共享」后，应用运行且系统清醒期间继续提供文件；关闭后，退到后台会停止共享。退出应用或系统睡眠会中断传输；对端暂时不可达或唤醒后连接失效时，进程内自动重试最长 30 分钟，超过后回到应用可重试续传，详见 [传输恢复](传输恢复.md)。没有系统服务、托盘常驻、开机自启或防睡眠机制。

Windows 的平台通道 `uri` 字段实际传递本机绝对路径，不转为 `file://`；这些路径只供本机存储与打开操作，不发送给对端。对端使用不透明媒体 ID 与相对目录元信息，通过 gRPC 请求文件。数据库位于 `%LOCALAPPDATA%\Tamayura\databases`，预览/临时文件位于 `cache`，未完成下载分片位于 `transfers`。设备 UUID 和后台共享设置保存于当前用户的 `HKEY_CURRENT_USER\Software\Tamayura`；移动源码或 EXE 不会改变这些位置。清理应用数据库会失去缓存、目录配置与记录，清理 `transfers` 会失去未完成续传；外部共享目录和接收目录里的原文件不属于这些缓存。

原生入口为 `windows/runner/windows_platform.cpp`，发现由 `lan_discovery.cpp` 与 `discovery_core.cpp` 处理，目录/文件与预览由 `windows_storage.cpp`、`storage_core.cpp` 处理；`lib/data/platform_database.dart` 在 Windows 配置共享的 FFI 数据库工厂。`windows/tests` 独立测试发现元数据校验及原生存储边界，`test` 保留跨平台业务与界面回归。

实际 Windows Runner 编译还需要显式包含命令行解析与 COM 的系统头文件，避免借用其他头文件的间接包含；局部变量避开 Windows RPC 的 `small` 宏。资源管理器定位使用的 PIDL 保留 SDK 的指针限定符和所有权，并在结束时调用 `CoTaskMemFree`。这些接入由完整 Runner 构建验证，独立存储 CTest 不覆盖 Flutter 宿主编译。

## 下载分片与容量

当前未发布源码的 `saveDownload` 接收有序 `sourcePaths` 和 64 位 `expectedSize`。原生预先验证并持有所有私有分片句柄，按顺序直接写入接收文件，校验最终总量；不再生成 `complete.partial`。失败尝试删除新建目标，分片由任务生命周期管理。`transferSpace` 用系统 API 查询两卷可用容量及同卷标识，未知值省略。暂停或删除等待原生保存返回后才释放暂存，完成保存与删除竞争时保留实际保存记录。详见 [下载存储与清理](下载存储与清理.md)。

已补有序分片、大小不符、缺失/越界分片、零字节文件及容量测试；本轮在 macOS 执行了 Dart Windows 桥接、源码白名单及可移植发现核心检查，Windows 专属存储测试与完整 Runner 编译仍需 Windows 主机。

## 准备 Windows 开发环境

1. 安装 Git、Flutter **3.47.6**（随附 Dart **3.13.5**），将 Flutter 的 `bin` 加入 `PATH`。源码包含 protobuf 生成文件，普通构建无需 protoc。首次依赖解析及原生资产构建需要联网。
2. 安装 **Visual Studio 2022**，勾选 **Desktop development with C++（使用 C++ 的桌面开发）**，保留 MSVC x64/x86、Windows SDK 和 C++ CMake tools。仅安装 Visual Studio Code 无法代替 C++ 工具链。
3. 将源码 ZIP 完整解压到可写目录，例如 `C:\dev\Tamayura`；不要在 ZIP 内直接运行，不要把其它电脑的 `.dart_tool` 或 `build` 目录复制过来。此 Windows 源码交接包仅含 Windows 所需项目文件，没有 Android/macOS 原生工程。
4. 在项目根目录打开 PowerShell，检查环境并启动：

```powershell
flutter --version
flutter doctor -v
flutter devices
flutter pub get
flutter run -d windows
```

`flutter doctor -v` 中 Windows 和 Visual Studio 检查应通过，`flutter devices` 应出现 Windows desktop。Android 工具链不参与 Windows 构建，不必为 Windows 调试安装 Android Studio。原生测试脚本会优先使用 PATH 中的 CMake，否则查找 Visual Studio 2022 自带的 CMake 和 CTest。

也可安装 Visual Studio 2022 Build Tools 的 VCTools 工作负载及 MSVC、CMake、Windows SDK 组件；本次实际使用 Build Tools 17.14.42、MSVC 19.44.35229 与 SDK 10.0.26100.0，具体组件见 [发布与打包](发布.md)。打包脚本要求 x64 构建主机；Flutter 3.47.6 自动采用主机目标架构，不支持 `build windows --target-platform` 参数。

环境准备依据 [Flutter Windows 开发环境说明](https://docs.flutter.dev/platform-integration/windows/setup)。Windows DNS-SD 使用微软的 [DnsServiceBrowse](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsservicebrowse)、[DnsServiceBrowseCancel](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsservicebrowsecancel)、[DnsServiceRegister](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsserviceregister) 与 [DnsServiceDeRegister](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsservicederegister)。停止浏览/注册后仍可能收到异步完成回调，原生层保留操作上下文到回调完成，并阻止旧会话再发送事件。发现丢失使用 TTL=0 提示和定期解析失败判定，受系统 DNS 缓存与重试间隔影响，离线状态可能延迟；应用仍会在连接和下载时重新确认对端身份与连通性。

## 首次连接与防火墙

双方连接同一个可信局域网，在 Windows 中将该网络设置为「专用网络」。首次启动提示 Windows 防火墙访问时，仅允许应用访问专用网络；无需允许公用网络或关闭防火墙。应用无账号、鉴权或 TLS，仅适用于自己的可信局域网。

Windows 需要接收 gRPC TCP 连接：默认端口是 `50728`，占用时可使用其它端口，应以「设备」页展示的本机地址和端口为准。建议按应用程序路径允许专用网络入站连接，避免只放行固定 `50728` 后动态端口仍被阻止。Debug 和 Release 位于不同路径，换路径后可能需要重新确认防火墙规则。mDNS 依赖本地网络的 UDP `5353`，受 Windows 服务、防火墙、网络策略和路由器组播转发影响。

在设置中选择一个含少量照片的共享目录以及独立接收目录；不要把接收目录放在共享目录中，以免下一次扫描再次共享下载副本。在双方「设备」页等待发现，失败时先使用另一台设备显示的 `IP:端口` 手动连接：手动连接正常通常说明 TCP 可达，下一步检查 mDNS；手动连接也失败时检查地址、防火墙、网络类型、VPN、访客网络或 AP 隔离。不要为排查问题关闭整机防火墙。

## 检查、构建与打包

在 Windows PowerShell 中执行：

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-windows-native.ps1
```

最后一条仅对本次进程设置脚本执行策略，不更改全局策略。原生脚本以 Visual Studio 2022 / x64 配置 `windows/tests`，构建 Release 后执行 CTest；缺少测试或测试失败会报错。需要完整预览包时直接执行以下脚本，它会重新要求格式、静态分析、所有 Flutter 测试和 Windows 原生测试通过，再构建 Release：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
```

输出为 `dist/0.5.0/Tamayura-0.5.0-windows-x64.zip` 和独立 `SHA256SUMS-windows`，版本始终取自 `pubspec.yaml`。脚本核对 EXE 的数字版本，并打包、核对完整 `build/windows/x64/runner/Release` 文件清单，包括 Flutter 引擎、插件、SQLite 原生资产与 `data`。不可只发送 `Tamayura.exe`。脚本不改已有 Android/macOS 产物的联合校验文件。

Flutter 测试会在 `build/native_assets/windows/native_assets.json` 写入构建机绝对 DLL 路径，该清单只供测试使用。CMake 安装时排除它并清除旧 Release 目录的同名残留；正式程序继续使用 `data/flutter_assets/NativeAssetsManifest.json` 和包根目录的 `sqlite3.dll`。打包入口要求 SQLite 存在且测试清单未残留，解压启动时核验实际加载的 SQLite 来自解压目录。

接收者完整解压 ZIP 后运行 `Tamayura.exe`。机器需具备 Microsoft Visual C++ x64 运行库；缺少 `VCRUNTIME140.dll` 或 `MSVCP140.dll` 时安装微软官方 [最新支持的 Visual C++ Redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)，不要从不明站点单独下载 DLL。当前 ZIP 未签名、未制作安装器、未发布到 Microsoft Store，系统可能提示来源未知；确认包来源与 SHA-256 后再运行。

```powershell
Get-FileHash .\dist\0.5.0\Tamayura-0.5.0-windows-x64.zip -Algorithm SHA256
Get-Content .\dist\0.5.0\SHA256SUMS-windows
```

`.github/workflows/windows.yml` 使用 `windows-2022` 和 Flutter 3.47.6 执行同一打包入口，并保存 ZIP 与校验文件。只有实际工作流成功才能记为 CI 验证通过。

## 从 Mac 准备源码交接包

Mac 无法代替 Windows 构建，可在项目根目录使用 Python 3.10+：

```sh
python3 scripts/test-windows-source.py
python3 scripts/package-windows-source.py
```

生成 `dist/0.5.0/Tamayura-0.5.0-windows-source.zip` 及 `SHA256SUMS-windows-source`。该包是当前工作区的源码快照，不能当作 Windows 可执行包。脚本用目录与扩展名白名单纳入 Windows 构建所需源码、资源、文档、锁文件和脚本，排除其它平台原生工程、签名密钥、`key.properties`、`local.properties`、`.git`、`.dart_tool`、Flutter 临时目录、`build`、`dist` 与缓存，并拒绝源码符号链接。交接前重新生成，使 ZIP 与最终修改一致。

## Windows 验收清单

- [x] 已记录通用工具链要求和脱敏验证结果；Windows / Visual Studio 工具链检查、格式、分析、370 项 Flutter 测试、Windows CTest 2/2、Release 构建均通过（2026-10-17）。
- [ ] 从完整 Release ZIP 启动并显示正确版本，窗口缩放、最小化、浅色/深色、Ctrl 快捷键、关闭窗口正常。
- [ ] 目录选择器选择与取消、中文/日文/空格路径、多个共享根、父子目录拒绝、失效目录和权限不足提示正常；目录联接、符号链接与非法保存路径无法越出授权目录。
- [ ] Windows ↔ Android 16+、Windows ↔ macOS 15+ 双向自动发现、手动 IP、设备名更新、记住设备、离线预览正常；Android/Mac 扫描 Windows 连接二维码正常。
- [ ] 普通照片和系统支持的视频产生缩略图；损坏/不支持媒体显示占位；大相册分页同步、中途断网/重启恢复正常。
- [ ] 点一次下载小图片、超过 50 MiB 的视频；中文路径、同名设备/目录/文件不覆盖；原文件大小与 SHA-256 一致；系统打开、资源管理器定位正常。
- [ ] 下载取消、重试、断网、对端退出、Windows 休眠/唤醒、关闭应用后重启恢复正常；未完成分片仍可续传。
- [ ] 最小化后接收继续；后台共享开/关行为符合设置，退出后不再共享，重新打开可恢复使用；不声称睡眠期间持续传输。
- [ ] 私人网络防火墙允许应用后可互传；端口占用时连接展示的实际端口；访客网络/隔离网络失败时提供可理解的错误。
- [ ] 在无 Flutter/Visual Studio 的另一台 Windows x64 机器上验证完整 Release 包与运行库依赖；Windows 10 1809 与 Windows 11 分别验证后再扩大支持声明。

调试失败时保存原始日志并说明触发操作。例如：

```powershell
flutter run -d windows -v *> windows-debug.log
```

日志可能包含本地路径和局域网地址，提交问题前可先移除不希望公开的内容。历史数据不兼容时按项目 v1.0.0 前策略清空应用数据或重新配置；不要求旧数据库迁移。
