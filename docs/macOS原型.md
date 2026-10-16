# macOS 实现与验收

macOS 自 0.3.0 起与 Android 一起提供本地签名试用包，最低系统 **macOS Sequoia 15.0**，覆盖 Tahoe 26 及后续版本；不增加更早 macOS 的兼容分支。Android 的最低版本仍为 Android 16（API 36）。两端共用 Flutter 相册、设备记忆、SQLite 元信息和缩略图缓存、gRPC v3 协议及持久分片下载逻辑。

![macOS 桌面界面原型](screenshots/macos-prototype.png)

上图为 Flutter widget 渲染，使用虚构设备和合集及占位封面，用于检查桌面布局。实际 App 与设备验证结果见下文；文档不保存真实相册截图。

## 使用与开发

需要 Flutter 3.47.6 / Dart 3.13.5、完整 Xcode 及其 macOS SDK。仅安装 Command Line Tools 无法完成 Flutter macOS App 的构建。按 [Flutter macOS 环境配置](https://docs.flutter.dev/platform-integration/macos/setup) 初始化 Xcode，并用 `flutter doctor -v` 检查环境。原生插件使用项目的 Swift Package Manager 集成。

```sh
FLUTTER_SWIFT_PACKAGE_MANAGER=true flutter pub get
FLUTTER_SWIFT_PACKAGE_MANAGER=true flutter run -d macos
```

如果刚安装 Xcode 后 `xcode-select -p` 仍显示 Command Line Tools，可在当前终端先运行 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，再执行上述 Flutter 命令。打包脚本会自动处理这一情况，无需修改全局工具链选择。运行 macOS 版不需要 iOS 模拟器；当前原生插件均通过 Swift Package Manager 集成。

1. Mac 与 Android 连接同一局域网，打开双方 Tamayura。
2. Mac「设置」中通过系统文件夹选择器添加共享目录并选择接收目录。多个共享根可以独立移除，拒绝重复及父子重叠的目录。
3. 首次出现系统局域网权限提示时允许访问。「设备」中会发现同网络的 Tamayura，也可输入另一端的私有 IPv4 地址及端口；默认端口 `50728`。Mac 可以显示配对二维码，也可以授权相机扫描另一端的二维码。
4. 相册按「来源设备 / 共享目录」展示合集。点击媒体下载原文件，按「来源设备名 / 共享目录名 / 原有子目录 / 文件名」保存。已缓存的缩略图可离线查看。
5. 下载期间可切换应用或最小化窗口。需要 Mac 在后台提供共享文件时打开「后台共享」。退出 Tamayura 或系统睡眠会中断服务；重新打开后可重试未完成下载并复用已有分片。相册元数据与缩略图也持久保存断点，重启后可继续同步，详见 [同步进度与断点恢复](同步进度.md)。

局域网权限被拒绝后，可在「系统设置 → 隐私与安全性 → 本地网络」检查 Tamayura；相机权限也在隐私与安全性中管理。不需要为手动 IP 连接授予相机权限。防火墙或路由器的客户端隔离也可能影响连接。

## 实现

### 共用逻辑与桌面界面

- Dart 平台接口将 Android 原生任务调度与 macOS 的进程内下载分开，媒体协议、设备身份核验、SQLite、缓存增删和下载校验继续共用。
- macOS 宽窗口使用侧栏；窄窗口保持可用的导航。相册、设备、设置、下载任务及预览复用现有界面，支持浅色、深色及跟随系统。
- macOS 下载调度复用 `TransferRunner`，包括超过 50 MiB 的四路并发、SQLite 任务状态、取消、失败重试及持久分片。任务结束、取消和关闭时释放运行资源，重启后把没有执行器的活动任务转为可重试状态。
- macOS 不使用 Android JobScheduler、通知授权或电池优化设置。后台共享只表示应用进程仍运行且系统清醒时继续服务；不安装常驻守护进程，也不自动开机启动或远程唤醒。

### 后台运行、App Nap 与睡眠

macOS 普通失去焦点不等于应用退出。App Nap 会在系统认为后台应用没有重要工作时降低 CPU 优先级、延迟定时器并限制 I/O；这可能表现为响应变慢或传输停顿。系统睡眠是另一个状态，应用的活动声明不代表睡眠期间仍可进行局域网传输。

此次代码检查发现原生端未声明共享/下载活动，存在被 App Nap 限速的风险；未采集到修复前真实 App Nap 状态，不能据此断言每次后台停顿都是该机制导致。另一个可由状态序列确认的问题是：窗口 `hidden → inactive` 后，原逻辑忽略 `inactive`，导致可见但未获焦点的窗口仍停服。

当前行为：

| 场景 | 共享与下载 |
| --- | --- |
| 切到其他应用，窗口仍可见或被遮挡 | 失去焦点不主动停止共享；运行中的共享/下载具有 App Nap 活动保护 |
| 隐藏或最小化，后台共享开启 | 继续共享和下载，具有活动保护 |
| 隐藏或最小化，后台共享关闭 | 停止 gRPC 监听、Bonjour 与目录同步；已发起的接收下载独立继续并保留保护 |
| 窗口重新可见但未获焦点 | 恢复共享，不额外触发相册刷新 |
| 系统睡眠、合盖导致睡眠、退出应用或关闭最后一个窗口 | 不保证继续传输；恢复后可手动重试并使用已有断点 |

原生 `NetworkActivity` 使用 `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)`。共享服务随 `startDiscovery` / `stopDiscovery` 持有或释放一份所有权；它们对应控制器的 gRPC 网络启停。每个进程内下载通过 `setTransferActivity(taskId, active)` 独立持有所有权，从暂存目录准备前覆盖网络重试和最终文件导出，在 `finally` 释放。重复请求幂等，停止共享或结束一个下载不会释放其他任务仍需要的活动。最后一个所有者结束或原生对象释放后调用 `endActivity`。

首次目录扫描发生在 gRPC/Bonjour 启动前，因此原生扫描另有一份相同策略的短期活动，使用 `defer` 在成功、异常或取消时结束，补齐冷启动大目录扫描的保护。

活动声明不依赖“后台共享”偏好本身，也不依赖窗口是否最上层；实际提供服务时就生效。没有永久禁用全应用的 App Nap，也不添加防止屏幕关闭或阻止系统空闲睡眠的选项。Flutter `AppLifecycleCoordinator` 将 macOS 的窗口可见性与焦点分开，Android 的 `inactive` 保持原有语义。

自动化覆盖原生活动选项、共享/多下载交错、重复启停、退出释放、真实 ProcessInfo 调用，以及 Flutter 状态转换、活动获取失败、自动重试、完成、取消、释放异常与并发下载。手工验收时可在“活动监视器 → 能耗 → App Nap”观察状态：共享开启或有下载时，遮挡/最小化窗口后由另一台设备请求目录和大文件；全部活动停止后应允许系统自行决定是否进入 App Nap。系统睡眠与 Sequoia/Intel 实机仍需分别验收，不能以单元测试代替。

官方依据：[App Nap 的触发与限速](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)、[声明长时间用户活动及结束活动](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html)。

2026-10-16 本次验证：`flutter analyze --no-pub` 无问题；`flutter test --no-pub` 全部 289 项通过；`scripts/test-macos-native.sh` 的 15 项存储/媒体测试与新增 6 项活动管理测试通过。Release 通用 App 构建成功，主程序和 Dart App framework 均含 arm64/x86_64，`codesign --verify --deep --strict` 通过。尚未进行长时间后台双机传输及真实 App Nap 状态对照测试。

### 原生目录与媒体

- `NSOpenPanel` 获取用户选择的目录，保存 security-scoped bookmark，在重启后恢复目录授权。权限丢失或目录不可用时报告错误并允许重新选择。
- 递归扫描图片和视频的轻量元信息，非媒体文件不进入共享目录快照；向对端只暴露媒体 ID，不暴露本机路径或 bookmark。
- 扫描普通文件夹，跳过隐藏文件、符号链接和应用/图库包内部目录；不直接读取 Apple「照片」的 `.photoslibrary`。其中的媒体需要先从「照片」导出到普通文件夹，再加入共享。
- 原生图片/视频缩略图及限制尺寸的图片预览；缩略图失败时使用占位，原文件仍可尝试下载。
- 范围读取有边界校验；扫描与导出拒绝越界路径和符号链接逃逸。接收文件保留来源目录层级，同名文件另存，不覆盖已有文件。
- 打开文件交给系统默认应用，分享使用系统分享面板。

### 发现与配置

- Bonjour 发布并浏览 `_tamayura._tcp.`，TXT 字段与 Android 保持一致（`id`、`name`、`version=3`）；仅使用当前协议及 IPv4 局域网。
- macOS 使用独立的 `macos-` 设备身份，与可编辑的设备名称分离。二维码和手动连接继续使用共享 `LanEndpoint` 解析器。
- Mac 的 UUID 保存在应用本地偏好中，正常重启保持稳定；清空应用数据会生成新身份，不尝试读取硬件序列号。与 Android 的系统身份来源不同，但对端按相同协议将其作为独立设备记忆。
- Debug/Profile 与 Release 都启用 App Sandbox、网络客户端和服务端、用户所选文件读写、应用 bookmark 与相机权限。`Info.plist` 声明局域网用途、Bonjour 服务和相机用途。
- 所有 Runner 构建配置最低系统为 `15.0`，复用 `assets/branding/app_icon.png` 生成 macOS 图标。本地试用包使用 ad-hoc 签名，未配置 Developer ID 公证。

Apple 的 [本地网络隐私说明 TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) 与 Flutter 的 [macOS 沙盒配置](https://docs.flutter.dev/platform-integration/macos/building) 是权限配置依据。

## 检查与打包

```sh
flutter analyze
flutter test
scripts/test-macos-native.sh
scripts/package-macos.sh
```

打包脚本先检查完整 Xcode（必要时自动使用 `/Applications/Xcode.app`），执行格式、静态分析、Flutter 与原生测试，再构建 Release App，核对版本、最低系统、通用架构和签名。脚本按应用版本生成 ZIP；0.3.0 路径为 `dist/0.3.0/Tamayura-0.3.0-macos.zip`，另写 `SHA256SUMS-macos` 独立校验文件，不覆盖双端 `SHA256SUMS`。CI 入口为 `.github/workflows/macos.yml`。版本、安装说明和实际发布检查见 [0.3.0 试用版本说明](releases/0.3.0.md)；本地包未公证，不上传远端 Release 或应用商店。

## 验证边界与双机验收

0.3.0+6 发布检查已完成：49 个 Dart 文件格式、静态分析、259 项 Flutter 测试、124 项 Android 原生及插件测试、15 项 Swift 原生测试和 3 项隔离原生宿主 XCTest 均通过；双端 Release 构建、版本、架构、签名与产物校验通过。macOS ZIP 已实际解压复核版本、通用架构和深度严格签名，CRC 与 SHA-256 也通过。隔离 XCTest 使用独立 Bundle 与空 Dart 入口，最终 Release 使用 `lib/main.dart`；该宿主测试不属于真实 App 功能启动冒烟。精确产物字节数、SHA-256 与待验收项目见 [0.3.0 发布说明](releases/0.3.0.md)。

以下为 2026-10-10、版本号仍为 0.2.0+5 时的 macOS 开发验证记录，用于保留平台实现的验证范围；不是 0.3.0 发布包的检查结果。0.3.0+6 的构建、签名和测试结果另记于 [本次发布说明](releases/0.3.0.md)。

| 检查 | 结果 |
| --- | --- |
| Dart 格式 | 48 个文件，0 个需要调整 |
| Flutter 静态分析 | 无问题 |
| Flutter 全量测试 | 249 项通过；含桌面布局、平台通道、下载取消/重试、真实 gRPC 下载与安卓回归 |
| Android 应用原生测试 | 69 项通过 |
| Swift 原生测试 | 15 组通过；含图片、MOV/MP4 实际缩略图、目录授权恢复与移动、符号链接、层级保存及范围读取 |
| 原生宿主与工程配置 | Xcode 27.0 实际编译并链接 FlutterMacOS、mobile_scanner、package_info_plus 和 sqflite_darwin；plist、权限与源码注册检查通过 |
| Xcode RunnerTests | 3 项通过，实际宿主执行；覆盖最低系统与权限、路径逃逸拒绝及目录重叠判定 |
| macOS Release 构建 | 成功生成 Tamayura.app；arm64 / x86_64 通用产物，最低 15.0，ad-hoc 签名验证通过 |
| 原型打包 | `scripts/package-macos.sh` 全流程通过；ZIP 为 20,679,350 字节，SHA-256 与 ZIP 完整性校验通过 |
| 实际界面 | M2 Pro / macOS 26.6.2 启动成功；相册与设置侧栏切换、系统目录选择器打开及取消正常 |
| Android → Mac 相册 | 自动发现同局域网 Android 设备，完成 6473 项媒体元信息同步并显示真实合集封面；未下载原文件 |

上述开发验证已在完整 Xcode 下完成 App 构建及真实插件链接；当时 Android 原生测试通过 69 项。Sequoia 与 Intel 实机、目录选择与授权持久化的完整 GUI 流程、权限拒绝与恢复、相机、系统分享、双向原文件传输及异常网络场景尚未完成真机验收；不能以元信息同步成功代替全部双机验收。CI 配置完成不等于 CI 已运行成功。

桌面组合快捷键已通过 widget 测试；本次 GUI 自动化能操作侧栏、Tab 焦点及系统退出，但发送 Command 组合导航键未观察到换页，尚未确定是自动化输入还是应用问题，需要实际键盘复核。

验收至少覆盖：

- Sequoia 15 与 Tahoe 26 启动、窗口缩放、最小化、重新激活、关闭与退出；后续 macOS 版本继续纳入回归。
- 双向自动发现、系统改名、断网重连、手动地址、Mac 显示二维码及相机扫码；拒绝局域网或相机权限后的提示与恢复。
- 多目录、中文路径、父子重叠、重启授权恢复、目录删除和权限撤销；共享目录里的符号链接不能导出授权根以外的文件。
- 双向相册同步、渐进缩略图、增删、离线浏览；在不同分页中断并重启双方，确认已就绪预览保留、缺失缩略图与后续页继续，完整成功前不删除旧缓存。
- 小图片与大于 50 MiB 视频、四路范围流、断网续传、取消后重试、退出后重试、目标文件冲突与磁盘写入失败。
- 关闭后台共享后隐藏窗口不再共享，开启后系统清醒时最小化仍可访问；系统睡眠中断后恢复。
- 下载文件的目录层级、图片预览、默认应用打开、系统分享，以及 Release 沙盒与 Debug 行为一致。

当前仍仅支持可信局域网私有 IPv4，无账号、鉴权或 TLS；不实时监听目录，不同步内容修改，不自动下载整个相册，不做跨设备内容去重。

与 Android 一样，本机重新扫描时会撤销旧的文件读取映射；扫描期间正在接收的对端可能需要在扫描完成后重试。关闭 Mac 最后一个窗口会退出应用，最小化窗口不会退出。
