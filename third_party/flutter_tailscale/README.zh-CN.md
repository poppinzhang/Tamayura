# Flutter-Tailscale

简体中文 | [English](README.md)

Flutter-Tailscale 是可供原生 Flutter 应用复用的 Tailscale 接入组件，由 Go `tsnet` 核心与 Flutter 插件组成。Tamayura 是首个接入应用。

**当前状态：2026-11-15，未发布实现。** 仓库已包含 Dart/Flutter 包、Go `tsnet` 核心、Android 网络适配、原生构建脚本与自动化测试。本机鉴权传输和生命周期检查已通过；内嵌节点的真实互联网连接、Android 后台行为仍需真机验证。尚未发布软件包或 Release。

## 已实现能力

- 可选的应用内登录，第一阶段连接 Tailscale 官方管控，持久保存每个应用独立的节点身份。
- 提供节点状态与可见对端信息，不要求用户提供整个 tailnet 的管理 API 令牌。
- 在应用服务与 Tailscale 网络之间提供出站、入站 TCP 转发。
- 提供生命周期、连接和状态快照的 Dart 接口，gRPC 适配器使用独立 import。
- 与宿主应用原有的局域网能力独立运行。

运行时面向 Android、macOS、Windows 和 Linux；构建与本机传输检查不等于各平台真实网络验收，具体见实现记录。iOS 是后续目标。Flutter Web 需要另一种方案。独立项目不限定每个平台都启动独立进程，桌面辅助进程与移动端原生库可以实现同一套接口。

宿主应用继续负责自己的服务识别、业务授权、LAN / Tailscale 选路和后台任务。复用组件不会自动共享其他应用的登录或 Tailscale 节点身份。Headscale 配置保留为后续按需扩展。

## 阅读入口

接入从[实现与验证记录](docs/08-implementation.md)和[最小消费示例](example/README.md)开始。01–07 保留原设计讨论，其中的建议 API 和未实现能力不构成当前公共接口。

| 文档 | 内容 |
| --- | --- |
| [范围与架构](docs/01-scope-and-architecture.md) | 组件边界、数据流、资源归属与建议项目结构 |
| [接口与生命周期](docs/02-api-and-lifecycle.md) | Dart 接口草案、状态、事件、控制通信、错误与身份持久化 |
| [传输与安全](docs/03-transport-and-security.md) | 本机鉴权、TCP 转发、gRPC 适配、对端身份与资源限制 |
| [平台适配与打包](docs/04-platforms-and-packaging.md) | 桌面与移动端运行方式、生命周期、构建和分发要求 |
| [Tamayura 接入](docs/05-tamayura-integration.md) | 发现顺序、双路径状态、RPC、下载与待定产品行为 |
| [验证与路线图](docs/06-validation-and-roadmap.md) | 原型门槛、测试矩阵、网络测量与交付条件 |
| [决策与资料](docs/07-decisions-and-references.md) | 已确认范围、推荐方案、待决事项与一手资料 |

出站 TCP 使用会话证书固定的本机 TLS 和经过鉴权的 CONNECT；入站发布使用明确的来源节点允许名单，以及 Go 与 Dart 自持监听之间的固定证书双向 TLS。gRPC 使用 `package:flutter_tailscale/grpc.dart` 中的 `TailscaleChannel`，普通 channel 无法完成这些握手。

变更见 [CHANGELOG.md](CHANGELOG.md)。本项目不声明为 Tailscale 官方 SDK；项目自身许可证与包发布信息尚待确定。
