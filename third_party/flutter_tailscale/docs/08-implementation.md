# 当前实现与验证

更新：2026-11-15。本文描述未发布源码，优先于 01–07 中的接口建议；没有发布软件包、Tag 或 Release。

## 组成与构建

| 目录 | 内容 |
| --- | --- |
| `lib/` | Flutter/Dart 生命周期、状态、peer 引用、受保护 TCP 与 gRPC 适配 |
| `native/bridge/` | 固定版本 tsnet 节点、控制命令、目标绑定、TLS、来源策略与所有者 |
| `native/cmd/` | 桌面辅助进程及 Android C ABI |
| `android/` | Flutter 多 Engine 观察者、Android 网络接口快照与原生资产构建 |
| `scripts/` | 原生构建及对应目标依赖的第三方许可证收集 |
| `test/` | Dart 模型、协议、真实本机 TLS/CONNECT、gRPC 与原生辅助进程检查 |

固定核心版本为 Tailscale **1.104.7**、Go **1.27.4**。SDK 适配器固定 Dart gRPC **4.2.0**，测试使用 Flutter **3.47.6** / Dart **3.13.5**。`native/go.sum` 和 `pubspec.lock` 保存依赖解析结果。Go 可通过 `GOTOOLCHAIN=auto` 取得项目要求的工具链；最终应用不下载编译工具。

桌面构建：

```sh
scripts/build-native.sh darwin arm64 /absolute/output/flutter-tailscale-bridge
scripts/build-native.sh windows amd64 /absolute/output/flutter-tailscale-bridge.exe
scripts/build-native.sh linux amd64 /absolute/output/flutter-tailscale-bridge
```

实际输出路径由调用者提供。打包时把辅助程序放到宿主可执行文件同目录，或调用 `TailscaleNode.open(executablePath: ...)` 指定受信的绝对路径。macOS Universal 由宿主分别构建 arm64/amd64 后合并并签名；这里不修改宿主签名或安装系统服务。辅助程序旁的 `.NOTICES.txt` 必须随包保留。

许可证收集脚本对 Go 输出、许可文本及声明文件显式使用 UTF-8，不依赖 Windows 系统区域编码或 `PYTHONUTF8` 环境变量。Windows 原生构建由宿主 CMake 调用 Go 和 Python，以上 shell 命令用于提供 POSIX shell 的构建宿主。

Android 插件要求 API 36，使用 NDK 28.2.13676358；原生编译 API 35 与应用最低运行 API 36 是两个不同约束。Gradle 构建 arm64-v8a、armeabi-v7a、x86_64 共享库，将许可证置入 assets。构建脚本目前支持 macOS/Linux Android 构建宿主，不承诺 Windows Android 源码构建。JNI `.h` 和通知文本不混入最终 jniLibs。

## 当前接口

最小接入见[示例](../example/README.md)。`TailscaleNode.open` 只初始化，既不联网也不登录。`login` 必须由用户动作触发；首次使用直接调用 `login`，不能先要求 `start` 成功。`start` 仅恢复已经允许保存的身份；没有恢复标记时返回 `loginRequired`。宿主从 `login`/`status` 获取官方 HTTPS 认证链接并打开系统浏览器，SDK 不记录或自动广播认证链接。

状态为 `NodeStatus`，`controlState` 单独表达管控健康，不能据此拆除仍能通信的数据路径。候选为 `TailscalePeer`；`online` 只表示管控在线。`PeerRef(networkScope, nodeId)` 绑定已验证的本机注册作用域和远端稳定节点标识。当前 `networkScope` 是本机稳定节点 ID 与用户 ID 的哈希，不是所有节点共用的全局 tailnet ID；本机重新注册或切换身份后旧关联不再有效。IP 和名称均不是信任键。

`openTcp(peer, port: ...)` 为每次新连接取得目标租约，先校验 Go 会话证书，再发送 CONNECT capability。`publishTcp(port:, allowedPeers:, onConnection:)` 创建 Dart 自持的本机双向 TLS 入口，只接受 Go 当前会话证书；Go 通过 WhoIs 核验真实来源并匹配显式允许名单。源策略为空时拒绝全部来源。服务关闭先停止本机 mTLS 监听、拒绝新的流交付并销毁已有应用流，再等待可能阻塞的原生撤销响应。`ServiceLease.updatePolicy` 和 `close` 同时作用于新连接与已建立连接。

会话证书只存在于一次运行会话的内存中，两端按完整证书内容固定，并随会话轮换更换，因此有效期不承担安全作用。证书使用固定的 2000-01-01 至 9999-12-31 有效期，不随签发时刻变化：长期运行的节点不会因证书到期而无法把入站流交给宿主，系统时钟被校正也不会使本机握手失败。Dart 侧的发布监听按严格校验接受该证书，未使用 `onBadCertificate` 放宽。

控制协议 v1 采用继承管道上的 NDJSON，每帧最多 1 MiB；Android 的 `ft_request`/`ft_free` 使用同样的 JSON。初始化校验协议版本与所需安全能力。当前采用有界状态快照轮询，尚未实现草案中的 JSON-RPC 长度帧、有序事件、请求幂等记录和通用取消协议；网络操作有自己的截止时间。桌面控制超时会终止自有辅助进程以避免未知资源残留，进程内 FFI 不在 UI isolate 阻塞。

Android 初始化经过平台 MethodChannel，在后台线程经 JNI 请求核心；平台先原子登记 owner 再交给 Dart。Engine 销毁会释放已登记 owner；初始化尚未返回时销毁 Engine，返回的 owner 立即被释放，避免旧固定端口和节点所有者遗留。后续请求使用 isolate 中的 FFI。新增 4 项 JVM 测试覆盖登记/销毁先后顺序与正常释放；执行结果以宿主 Android Gradle 验证记录为准。

Android 原生核心按 `ownerId` 共享一个节点。前台和 UIDT Engine 各自初始化，使用相同私有状态目录与节点名。`dispose` 只释放本 owner 的资源，最后一个 owner 释放时停止节点；`stop` 与 `logout` 是应用级操作。跨进程状态目录锁拒绝第二个所有者，不会并发重写身份。停止保留身份，退出先禁止恢复并清理 SDK 节点子目录，不删除宿主数据库、媒体或下载分片，也不声称删除云端节点。

Android 网络接口使用 `java.net.NetworkInterface` 与 `ConnectivityManager` 提供给 Go 注册的 interface getter，避免直接依赖受限制的 netlink 枚举。默认网络变化会刷新快照；这不代替真机上的切网、DNS、蜂窝和后台任务验收。

Android 启动节点时将 `TS_LOGS_DIR` 指向应用私有状态目录。Tailscale 1.104.7 创建本地后端时，即使已禁用日志也会调用 `logpolicy.LogsDir`。在没有用户缓存和可写系统临时目录的应用进程里，该调用会引发 Go panic 并终止宿主。首次登录和恢复节点走同一启动流程。

## gRPC 与传输边界

`package:flutter_tailscale/grpc.dart` 提供 `TailscaleChannel` 和 `serveGrpcConnection`。CONNECT 完成后才交给 HTTP/2；应用 Protobuf 无需改变。`TailscaleChannel.lastConnectionFailure` 保留 SDK 的类型化连接原因，即使 grpc 4 把连接失败包装为 UNAVAILABLE，宿主仍可将可确认的证书/身份/本机鉴权拒绝与可重试网络错误分开，不能通过分析任意错误文本作判断。传输不重放 RPC，不把失败的新连接伪装成旧连接继续运行。

默认 gRPC 模式依赖 Tailscale 链路加密和本机受保护入口；没有额外的端到端应用 TLS 选项，不接受 TLS 配置后悄悄降级。当前 Go TLS 复制对依赖 TCP half-close 的任意协议不作兼容承诺。正常业务连接没有 SDK 统一空闲截止时间。

资源限制：Dart `SecureServerSocket` 不公开尚未完成的 TLS 握手连接，关闭监听后这些连接不会交付新的应用流，但恶意本机对端的未完成握手可能持续到对端关闭或进程结束。Go 发起的正常本机 TLS 握手具有 5 秒截止时间。当前实现不能宣称所有尚未认证的本机握手都具备独立超时和连接数上限。

gRPC 4.2.0 / http2 2.3.1 在客户端期限 RST 与服务器迟到 HEADERS 交错时可能关闭 HTTP/2 连接。SDK 保留期限错误并允许下一次操作建立新通道，不改写 HTTP/2 字节或自动重放原 RPC；宿主仍须在已有业务重试/续传边界恢复。测试验证取消、期限与新连接恢复，不保证期限后同一 TCP 连接继续存活。

## 本轮验证与尚未验证范围

已执行：

- `flutter analyze --no-pub` 无问题。
- 22 项 Flutter 测试全部通过，包含实际本机 TLS/CONNECT、分段响应与预读字节、128 KiB 双向字节、错误证书先于 capability 拒绝、握手拒绝/超时/上限、所有四种 gRPC 流模式、取消、期限与重连。
- 新增真实 mTLS 撤销回归：原生 unpublish 响应被人为阻塞时，已有应用连接立即断开，新连接被拒绝，先前未完成握手也不能交付新流；重复关闭只执行一次原生撤销。
- 其中 2 项由新构建的真实 Go 辅助进程执行，覆盖未登录初始化、首次 `start` 安全拒绝、跨进程状态锁、会话轮换、退出恢复标记、重复释放、重新打开以及多个 owner 的独立释放；没有进行真实登录。
- Go 核心 17 项单元与 race 检查通过；这些来源授权测试使用假 tsnet 后端和真实本机 TLS，不代表真实互联网验收。已交叉构建 macOS arm64/x64、Windows x64、Linux arm64/x64 与 Android 三种 ABI；Android arm64 ELF 加载段具备 16 KiB 对齐。交叉编译不证明目标系统实际运行，宿主安装包构建与验收以宿主实现记录为准。
- Windows x64 本机另已通过 17 项 Go 测试（`CGO_ENABLED=0`，未运行 Windows race）、SDK 静态分析和 22 项 Flutter 测试；后者使用宿主本次 Release 构建的真实 helper，两项原生检查均执行。Windows 打包与窗口级原生检查的具体范围见 Tamayura 实现记录。
- 2026-11-16 修复会话证书 30 天到期后入站流无法交付的问题，仅在 macOS 复验：Go 核心 18 项测试及 race 检查通过，新增用例在签发前 10 年与签发后 50 年两个时刻校验证书；`flutter analyze --no-pub` 无问题，23 项 Flutter 测试通过，其中 3 项由新构建的真实辅助进程执行，新增一项以辅助进程签发的证书完成 Dart 两端严格双向 TLS 握手并检查有效期。两项新增用例在修复前的实现上均失败。本次未在 Windows、Linux 或 Android 复验。

测试入口：

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
(cd native && go test -race ./...)
FLUTTER_TAILSCALE_HELPER=/absolute/output/flutter-tailscale-bridge flutter test --no-pub
```

另已分别执行 macOS helper 和 Windows 完整 ZIP 解压后 helper 的临时空状态目录匿名启动，取得官方认证 URL（未展示、未打开、未完成账号登录），核验日志未包含认证 URL 并清理临时身份。该检查发现并修复 macOS 用户态 tsnet 强制物理接口绑定绕过宿主路由的问题，以及上游 logtail 默认记录认证 URL 的问题；当前禁用 logtail 缓冲/上传。匿名启动结果不等于已登录节点互联验收。

未提供辅助程序环境变量时，2 项原生 smoke 测试明确跳过；不能把跳过写成通过。测试证书和私钥是公开、专用于回环测试的夹具，不用于真实节点。

仍需真实平台验收：官方首次认证/审批/恢复、两个内嵌节点互联、直连与 DERP、Android 16 蜂窝与 UIDT 前台 Engine 销毁后的连续性、系统切网/休眠/锁屏、最低系统和架构安装。官方独立 Tailscale 客户端的直连结果证明目标网络具有可行性，不能替代这些嵌入实现检查。iOS、Web、Headscale、UDP、系统 VPN 和通用服务发现仍未实现。
