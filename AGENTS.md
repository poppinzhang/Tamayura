# AGENTS

## 项目概述

本项目是一个用于局域网内多平台之间同步媒体文件的应用。

## 项目目标

* 跨平台的应用软件
* 支持局域网内自动发现设备
* 记住连接过的设备
* 支持指定当前设备用于分享（同步）的目录
* 软件内置的数据库需要保存其它连接过设备的媒体文件元数据信息
* 媒体元信息需要包括一张缩略图，方便本地设备大致查看对端设备的媒体文件
* 不需要实时同步对端媒体目录元数据，只需要在网络可连通的情况下进行更新
* 点击媒体文件后，再真正尝试连接对端并下载媒体文件到本地指定目录（也就是点一次就会下载到本设备）
* 不需要考虑媒体文件内容修改的情况，只需要同步增删
* 如果媒体文件大于 50M 则进行并发下载，提高下载速度
* 暂时仅限局域网内进行同步
* 暂不需要局域网内的安全验证

## 技术要求

* Android 最低支持 Android 16（API 36）；不兼容 Android 15 及更早版本。
* macOS 最低支持 Sequoia 15.0，支持 Tahoe 26 及后续版本；不兼容更早版本。

* 由于项目需要跨平台运行（Windows/macOS/Linux/Android/iOS），并帮我使用 Flutter 完成开发
* 默认使用 mDNS + DNS-SD 完成局域网的设备相互发现，也支持手动输入 IP 或 扫描二维码完成设备发现
* 媒体文件下载和程序之间的网络交互，请使用 gRPC 完成

## v1.0.0 前的兼容与升级策略

* 在到达 v1.0.0 之前，代码只维护当前最新逻辑，不要求不同应用版本之间的向前或向后兼容；数据库结构、配置格式和通信协议可以直接按当前需求调整。
* 优先保持实现简单，不为保留旧版本数据或支持旧版本行为添加兼容分支、数据迁移、旧配置转换、旧协议适配或回退逻辑，也不提前建设未来的升级框架。
* 允许覆盖安装，不强制每次卸载重装，也不保证旧数据可继续使用。出现不兼容时，可以要求卸载重装、清空应用数据，或直接清空并重建应用数据库，无需为避免这些操作增加兼容性代码。
* 测试验证当前版本的功能与异常处理，不要求验证历史版本兼容或数据迁移路径。到 v1.0.0 时再明确兼容与升级策略。

## 流程规范

* 不要把开发、打包、测试的环境隐私信息记录到项目中，包括内网地址、机器名、登录账号、SSH 连接信息、个人目录路径、密钥及凭据；代码、文档、日志和发布产物中的说明只保留必要的通用环境要求与脱敏验证结果。
* 每次修改或新增功能同步维护根目录 `CHANGELOG.md`，未发布改动放在 `## unstaged`；发布时改为 `## <版本号>` 并记录日期、已完成功能、改进、修复和已知限制，具体遵循 `docs/发布.md`。
* 功能确保提供完整的测试用例，新功能开发完后自动补全测试
* 能正确捕捉、处理异常错误
* 新功能的开发将实现细节自动记录到 docs 目录下
* 版本发布前需要所有测试全部通过
* 项目要支持发布与打包

## Git 提交署名

* Codex 实际参与的改动在提交消息末尾添加以下共同作者署名，并与正文空一行；保留提交者原有的 Git 作者身份，不修改全局 `user.name` 或 `user.email`。

  ```text
  Co-authored-by: Codex <codex@openai.com>
  ```

* 署名只用于实际参与的提交；不为署名创建空提交，不补署未参与的历史提交，不为贡献者展示改写已发布历史。Squash 合并时保留适用的共同作者署名。
* GitHub 根据邮箱关联账号并处理贡献统计；添加署名不等于已出现在 Contributors 页面，展示结果以 GitHub 为准。

## README 与开发文档的分工

* `README.md` 面向用户，使用英文；`README.zh-CN.md` 为对应中文版。两份 README 的功能、平台要求、使用步骤、安装入口和限制保持一致，并提供语言切换链接。
* README 介绍项目、实际可用的功能和使用方法，不放 AI 执行指令、开发环境搭建、测试命令、打包流程或逐次验证流水账。这些内容维护在本文件及 `docs/`。
* 介绍当前源码功能时，明确区分 `CHANGELOG.md` 中的 `unstaged` 与已发布安装包；不能把尚未发布的功能写成既有安装包已支持，也不能把旧版测试数量和历史验收结果作为当前状态。
* 实现细节写入对应的 `docs/` 文档，发布流程以 [发布与打包](docs/发布.md) 为准，历史交付及验证范围查看 [版本记录](docs/releases/)。不在多处复制版本流水账，不展示项目没有的渠道、服务或发布产物。

## 仓库结构与当前实现

* `lib/app/`：应用控制器、设备连接、页面状态与生命周期协调。
* `lib/core/`、`lib/data/`：媒体和下载模型、SQLite 元数据、同步断点及持久下载任务。
* `lib/network/`：gRPC 服务、客户端与范围下载；协议源文件为 `proto/media.proto`，生成文件为 `lib/network/generated/`。
* `lib/background/`：下载调度、后台执行与恢复；`lib/platform/` 对接各平台能力；`lib/ui/` 为共享 Flutter 界面。
* `android/`、`macos/`、`windows/`：当前已实现的原生平台工程。Linux、iOS 属于项目目标，不能仅因存在对应平台的界面测试就声称已支持运行或发布。
* `test/`：Flutter 单元、集成行为与界面测试；各平台原生测试入口见下文。`scripts/` 保存协议生成、原生检查与打包脚本，`.github/workflows/` 保存三平台 CI。

## 本地开发

统一使用 Flutter **3.47.6 stable / Dart 3.13.5**，依赖由 `pubspec.lock` 固定。先检查 `flutter --version`，依赖解析、测试和构建使用同一 SDK；升级工具链时同步检查 CI、打包脚本与开发文档。

| 平台 | 本机开发要求 | 运行入口 |
| --- | --- | --- |
| Android | Android SDK / Build Tools 36、JDK 21；源码编译目标为 Java 17，API 36 原生回归测试需要 Java 21 或更新版本 | `flutter run -d <device-id>` |
| macOS | macOS 15.0+、已安装并初始化的完整 Xcode；仅 Command Line Tools 不能构建应用 | `FLUTTER_SWIFT_PACKAGE_MANAGER=true flutter run -d macos` |
| Windows | x64 Windows、Visual Studio 2022 的“使用 C++ 的桌面开发”、Windows SDK 与 CMake | `flutter run -d windows` |

在项目根目录解析依赖：

```sh
flutter --version
flutter doctor -v
flutter pub get
```

macOS 使用 Swift Package Manager，依赖解析应执行 `FLUTTER_SWIFT_PACKAGE_MANAGER=true flutter pub get`。缓存完整的离线环境可使用 `flutter pub get --offline`。可用 `flutter devices` 查看 Android 设备标识。

Android 调试 APK 使用 `flutter build apk --debug`，输出为 `build/app/outputs/flutter-apk/app-debug.apk`；启用 USB 调试后可执行 `adb install -r build/app/outputs/flutter-apk/app-debug.apk`。debug 与 release 签名不同，签名冲突时先卸载；卸载会清除应用数据与目录授权，不能承诺保留缓存或下载任务。

## 检查与测试

公共检查在依赖解析后从根目录运行：

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub --coverage
```

按改动范围执行对应原生检查；发布前需完成全部适用平台的测试：

```sh
# Android：在有 Android SDK 和 JDK 21 的环境运行
(cd android && ./gradlew testDebugUnitTest)

# macOS：在 macOS 15.0+ 上运行
scripts/test-macos-native.sh

# Windows 源码交接白名单检查：可在非 Windows 主机执行
python3 scripts/test-windows-source.py
```

Windows 原生检查在 Windows PowerShell 运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-windows-native.ps1
```

`scripts/test-macos-native.sh` 检查 Swift 存储、网络活动、窗口行为及工程权限配置；Windows 脚本通过 CMake / CTest 执行原生测试。针对 `RunnerTests` 使用隔离 Bundle 和空 Dart 入口的测试结果只能记为原生宿主测试，不能代替正常应用的 GUI 验收。

`.github/workflows/android.yml` 执行发布工具回归、工作流语法检查、公共检查、Android 原生测试和 debug APK 构建；macOS、Windows 工作流调用对应打包脚本。日常 CI 处理分支、Pull Request 和手动检查；`.github/workflows/release.yml` 专门处理版本 Tag，校验版本与 CHANGELOG 后执行三平台测试和打包，全部通过才发布 Pre-release，配置与失败处理见 `docs/发布.md`。配置存在不表示 CI 已运行，历史通过不表示当前修改通过；仅记录本轮实际执行的检查与未验证范围。

自动化测试不能替代真实设备的 Wi-Fi 发现、目录权限、跨平台原文件传输、断网/睡眠恢复、系统菜单、扫码和分享验收。平台功能按实际支持范围验证，不把回环 gRPC 或独立原生宿主检查写成完整跨设备验收。

## 协议与生成代码

协议生成文件已提交，日常开发无需安装 `protoc`。修改 `proto/media.proto` 后安装 Protocol Buffers 编译器，并执行：

```sh
scripts/generate-proto.sh
```

脚本使用 `protoc_plugin 22.5.0` 重新生成 Dart gRPC 代码。协议源文件和生成结果一起提交，不手工修改生成代码；协议行为变化同步更新客户端、服务端、测试及相应实现文档，遵循 v1.0.0 前不维护旧协议兼容的策略。

## 打包与发布入口

应用版本与构建号以 `pubspec.yaml` 为来源，Android、macOS、Windows 保持一致。发布时遵循 [发布与打包](docs/发布.md)，不要将固定版本号写入通用脚本或把旧试用包视为当前源码产物。

发布必须按以下顺序执行，详细核验清单以 `docs/发布.md` 为准：

1. 同步并检查 `main`，更新版本、构建号、`CHANGELOG.md` 及相关文档，将本次发布内容 commit 并 push 到 GitHub 的 `main`，记录完整提交 SHA。尚未执行的测试和发布不得提前写为成功。
2. 对该已推送提交执行当前完整的本地测试、Release 打包及版本、系统、架构、签名、归档、隐私和校验和核验。macOS 主机执行 Android 与 macOS 流程；Windows 在 x64 Windows 环境执行，缺少该环境时以同一提交的 Windows 分支 CI 完整测试、打包和自动核验成功为准，不要求再下载产物，也不能用源码 ZIP 替代。已触发的三平台分支 CI 均通过后才进入下一步。
3. 确认本地 `main`、远端 `main` 与已核验提交一致，再为该明确提交创建附注版本 Tag 并推送 GitHub。测试失败或待发布提交变化时回到前两步，不给未经验证的新提交打 Tag，不强制移动既有版本 Tag。
4. 等待该 Tag 的准备、Android、macOS、Windows 和发布五个 job 全部成功，由 Agent 核对远端 Tag 实际提交、Release 正文与 Tag 内 CHANGELOG，以及三个包和 `SHA256SUMS` / `release.json` 共五个附件的元信息后报告完成。产物版本、系统、架构、签名、完整性、独立 SHA-256、联合元数据及上传后附件的大小、状态和可用摘要由 CI 自动核验；不再下载 Windows artifact 或 Release 附件重复手工比对，不得声称执行了下载校验。GitHub 自动生成的源码归档不计入五个附件。

仅讨论或维护流程时不执行发布；已授权发布时由 Agent 连续执行上述步骤并等待结束，无需人工下载、逐步确认或重复申请批准。首次配置完成后沿用当前签名 Secrets 与工作流 `GITHUB_TOKEN`，不将 Chrome 下载、`gh`、个人 API 令牌或新 OAuth 授权设为每次发布前提。实际失败时停在失败步骤处理，可在不覆盖公开版本、不移动 Tag 的条件下自动安全重试；发现遗漏、版本冲突或缺少必要条件时如实说明，不跳过检查。当前远端发布为 Pre-release，保留 macOS 未公证、Windows 未签名和真机验收范围的说明。发布后实际结果补充到对应版本记录，不回改已发布 Tag。

* Android：配置专用 release 签名后执行 `scripts/package-android.sh`，运行公共与原生检查、Release 构建及版本、系统、架构、签名和对齐核验，输出 APK 与独立校验和。按需生成 `flutter build apk --release --split-per-abi` 或 `flutter build appbundle --release`。缺失 release 签名配置时不得回退到 debug 签名。CI 签名通过 Actions Secrets 临时配置，详情见 `docs/发布.md`。
* macOS：执行 `scripts/package-macos.sh`，脚本运行公共检查、原生测试与 Release 构建，核验最低系统、版本、Universal 架构和签名，输出 `dist/<version>/Tamayura-<version>-macos.zip` 及 `SHA256SUMS-macos`。完整 Xcode 位于标准位置时可由脚本自动选择；非标准位置用 `DEVELOPER_DIR`，不修改系统全局开发目录。当前流程用于 ad-hoc 本地试用签名；公开发行需独立的 Developer ID 签名与公证流程，不能覆盖已有正式签名。
* Windows：在 x64 Windows 主机执行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1`，脚本运行公共检查、原生 CTest、Release 构建与完整目录归档核验，输出 `dist/<version>/Tamayura-<version>-windows-x64.zip` 及 `SHA256SUMS-windows`。必须分发完整 Release 目录，不能只发送 EXE；保留 SQLite、插件 DLL、Flutter 引擎和 `data`，排除测试专用且含本机路径的根 `native_assets.json`。
* 非 Windows 主机可执行 `python3 scripts/package-windows-source.py` 制作 Windows 构建输入。源码 ZIP 不能代替 Windows 可执行包或完成发布的证明。

打包脚本独立调用时会执行其完整检查。三平台可执行包全部完成构建、验证后才能标记全平台交付完成；联合校验和、`release.json` 与实际文件保持一致，各平台重打包不得覆盖其他平台的校验记录。构建及归档不得泄漏环境隐私，发布前核验归档及解压内容。签名配置和私钥不提交、不打印、不放入分发目录。

本地生成安装包不等于已创建 Git tag、上传远端 Release 或上架应用商店；发布渠道与交付状态以实际执行结果为准。正式公开发布还需真实跨设备验收及干净环境或 CI 重建。

## 实现约束与平台边界

* 当前网络范围为 IPv4 局域网，无账号、鉴权或 TLS。默认端口为 `50728`，mDNS / DNS-SD 服务为 `_tamayura._tcp`；手动只填 IP 时使用默认端口，扫码与自动发现使用实际广播端口。
* 元数据与缩略图保存到本地 SQLite，离线可浏览。同步不自动下载原文件，不跟踪原文件内容修改，也不进行跨设备内容去重。目录快照完整成功后才应用删除；断点恢复和独立缩略图缓存的约束见对应文档。
* 当前自动同步按设备分别计时，默认间隔 10 分钟，可设置 1–525600 的整数分钟；失败尝试也计时。手动刷新、明确重试、输入 IP 或扫码连接可立即尝试；上一次尝试失败的设备在 mDNS 上线边沿（发现会话中首次广播或下线后再广播）立即重试一次，重复广播不得触发同步或轮询。尝试时间与最后成功时间分开保存，不能把设备发现、在线探测或下载原文件当成相册同步成功。
* 自动发现的新设备先核验身份，再以「待确认」保存并提示一次，用户确认后才同步；拒绝的设备保留在列表中可随时开启，输入 IP 或扫码视为确认。忘记设备删除其目录、同步暂存和无引用缩略图，保留下载历史与已保存文件，不影响对端。
* 本地目录扫描仍遍历轻量元数据；手动刷新、目录变更立即扫描，返回前台按扫描间隔判断。扫描期间保持旧目录可用，成功后整体替换；被移除或授权失效的目录及时停止共享。
* 原文件按 `mediaReadChunkBytes`（暂定 2 MiB）分块读取与传输，修改时同步三端原生上限。大于 **50 MiB** 的媒体使用四个 gRPC 范围流并发下载，其余使用单流。分片持久保存以便续传，保存时按顺序直接写接收目录，不另建完整合并暂存。连续 30 秒无数据触发重连，持续 30 分钟无数据后失败；有进度的大文件不受固定总时限限制。
* 区分暂停与取消并删除；任务清理不得删除已保存的接收文件。保存失败保留可重试分片，峰值空间仍可能约为原文件两倍；容量预检不预留空间，部分 Android 文档提供者无法查询容量。文件保存与数据库登记不是跨系统事务，异常中断可能留下未登记副本。
* 本地媒体删除只处理用户选择的已接收文件及对应下载记录，保留远端原文件、相册元数据与缩略图。不要把本地删除扩展成远端删除或自动清理原文件；授权失败、I/O 错误与数据库清理失败需可见且可重试。
* Android 使用系统目录选择器和持久授权，不能直接授权存储根目录或 Download 根目录；共享目录拒绝重复或父子重叠。下载使用用户发起的后台传输任务；通知关闭仍可下载。来源端锁屏共享依赖“后台共享”及系统电源策略，不能承诺不受厂商限制。
* macOS 最低 15.0，Windows 当前目标为 Windows 10 1809+ / Windows 11 x64。Windows 没有相机扫码或系统分享面板；已下载文件可默认应用打开或在资源管理器定位。
* 桌面当前源码关闭窗口后通过菜单栏或托盘保留进程与已开始的下载；隐藏窗口后是否继续共享由“后台共享”控制。真正退出或系统睡眠会中断运行，不新增开机自启、后台系统服务或远程唤醒。托盘不可用时按文档处理，避免隐藏后无法找回。
* 媒体可用格式受平台解码能力限制；缩略图解码失败显示占位，不应中断其他有效条目的同步。原文件下载仍严格校验文件状态和范围。

## 实现文档导航

| 工作范围 | 相关文档 |
| --- | --- |
| 平台架构与原生能力 | [Android 原型](docs/Android原型.md)、[目录与设备发现](docs/android-storage.md)、[Android 16+](docs/android16.md)、[macOS 实现](docs/macOS原型.md)、[Windows 实现与调试](docs/Windows原型.md) |
| 设备与目录 | [设备身份与记忆](docs/设备身份与记忆.md)、[新设备确认与忘记设备](docs/新设备确认与忘记设备.md)、[设备排序](docs/设备排序.md)、[多目录共享与合集](docs/多目录共享与合集.md) |
| 同步与缓存 | [自动与手动同步](docs/自动与手动同步.md)、[同步进度](docs/同步进度.md)、[缩略图存储](docs/缩略图存储.md)、[单张缩略图容错](docs/单张缩略图容错.md) |
| 下载、保存与删除 | [传输恢复](docs/传输恢复.md)、[下载存储与清理](docs/下载存储与清理.md)、[相册本地原图](docs/相册本地原图.md)、[本地媒体删除](docs/本地媒体删除.md) |
| 后台与桌面生命周期 | [后台共享](docs/后台共享.md)、[桌面托盘与窗口生命周期](docs/桌面托盘与窗口生命周期.md) |
| 相册浏览与外观 | [合集显示模式](docs/合集显示模式.md)、[合集图片排序](docs/合集图片排序.md)、[合集快速滚动](docs/合集快速滚动.md)、[主题与外观](docs/主题与外观.md)、[应用图标](docs/应用图标.md) |
| 项目说明与发布 | [关于与项目缘起](docs/关于与项目缘起.md)、[发布与打包](docs/发布.md)、[版本记录](docs/releases/)、[变更日志](CHANGELOG.md) |
