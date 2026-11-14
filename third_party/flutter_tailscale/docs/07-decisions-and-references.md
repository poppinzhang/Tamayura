# 决策与资料

> 历史设计说明：本文保留 2026-11-11 的方案和待验证项。2026-11-15 已开始实现；当前 API、协议差异与实际验证范围以[实现与验证记录](08-implementation.md)为准，原“本轮只写文档”不再限制当前实施。
状态：2026-11-11。此清单区分用户已经确认的目标、推荐的实现方案和仍需作出决定的事项。设计草案不构成已实现的平台支持或发布承诺。

## 已确认目标

| 编号 | 目标 | 约束 |
| --- | --- | --- |
| C01 | 中间层独立成 Flutter-Tailscale 项目 | 通用组网和桥接可复用，Tamayura 为首个消费者 |
| C02 | 先完善方案、文档 | 当前不创建业务代码、插件骨架、依赖、构建配置或发布产物 |
| C03 | 首期接入官方 Tailscale 管控 | Headscale 按后续需求开放，不提前提供已支持的设置入口 |
| C04 | Tamayura 可选登录且 LAN 独立 | 未登录、失败或退出不改变原有 LAN 能力 |
| C05 | 支持发现远端设备并区分在线路径 | 网络候选经业务核验后才是应用设备，LAN / Tailscale 分别记录 |
| C06 | 相册和下载沿用同一业务体验 | 允许蜂窝网络访问家庭 Windows 机器，不能只验证前台调用 |
| C07 | 发现和新连接优先 LAN | 检查有界；LAN 成功后仍可发现新的 Tailscale 设备 |

## 推荐方案

以下决定在文档中用于构成一个可评审的完整设计，不等同于用户已经确认全部细节。后续获得开始实现的授权后先开展原型，再依据结果冻结方案与接口；本轮不实施原型。

| 编号 | 推荐选择 | 原因与验证点 |
| --- | --- | --- |
| D01 | Go tsnet 核心与 Flutter 插件同仓库维护 | 平台封装复用；核心不依赖相册与 Flutter UI |
| D02 | 桌面先验证辅助进程，Android 先验证进程内库 | 独立项目不要求各平台运行相同进程形态 |
| D03 | 控制通信与媒体字节分离 | 控制有界并可版本化；文件传输不阻塞状态事件 |
| D04 | 桌面专用继承管道，移动端平台调用 | 避免开放管理端口；共享同一操作与错误语义 |
| D05 | 每目标动态回环入口与 `ForwardLease` | 多目标并发可追踪、可撤销、与会话绑定 |
| D06 | 本机入口先核验 Go 服务端，再做鉴权 CONNECT 和字节透传 | 推荐会话级证书固定的本机 TLS，防止端口复用冒充；能力凭据授权调用方，SDK 封装两步握手 |
| D07 | gRPC 使用可选传输适配器 | 业务协议不变，连接层承担握手与流生命周期；固定版本验证 |
| D08 | 入站 `WhoIs` 加显式来源策略，缺失时拒绝发布 | 保留真实节点身份；透明流不承担方法级权限判断 |
| D09 | 每应用独立节点、单所有者、多 Engine 租约 | 重启保留身份，避免状态竞争；不同应用不共享凭据 |
| D10 | 状态快照加有序事件，旧会话统一失效 | 处理断线、重复、漏事件和账号切换后的迟到回调 |
| D11 | 首期只做 TCP | 满足当前 gRPC；UDP、通用服务目录和系统 VPN 后续另评估 |

## 尚待确定的问题

| 编号 | 问题 | 需要的输入 | 阻塞范围 |
| --- | --- | --- | --- |
| Q01 | 各平台 Go 嵌入形态、最低 SDK 和系统版本 | Windows / Android 原型及其他平台验证 | 宣布相应平台可用与固定构建链 |
| Q02 | Android 网络接口、切网和后台多 Engine 能否稳定运行 | 固定 tsnet / Go 版本的真机实验 | 移动端发布 |
| Q03 | Tamayura 如何让用户明确选择远端共享来源 | 产品确认，含未配对发现与访问权限边界 | 自动业务探测和媒体共享的完成验收 |
| Q04 | 本机端口生命周期、出站 Go 服务端身份与入站目标进程如何防止误转发 | 会话级本机 TLS 证书固定、各平台目标所有权验证、两端端口回收竞争测试 | 出站和入站生产转发 |
| Q05 | CONNECT、连接数、事件队列和流缓冲的最终预算 | 大文件、多目标、弱网与内存测量 | 性能和资源上限承诺 |
| Q06 | Tamayura 蜂窝自动同步、预取及自动续传默认值 | 产品需求 | 自动任务策略，不阻塞主动蜂窝操作 |
| Q07 | 传输中是否保持当前路径及详情显示位置 | 产品确认与时序测试 | Tamayura 路径迁移行为 |
| Q08 | 独立项目许可证、名称和软件包发布方式 | 维护者选择与依赖许可证清单 | 对外发布，不阻塞文档和原型 |
| Q09 | 后续是否支持 Headscale、iOS、UDP | 真实需求及专项验证 | 相应后续功能 |

上游 tsnet、Go 和 Dart 包的准确固定版本属于原型输出，不能仅将资料页标注的 latest 设为兼容基线。Tamayura 的当前工具链只是首消费者的测试输入，不自动成为通用组件支持范围。

## 易混淆的边界

| 表述 | 正确含义 |
| --- | --- |
| “已登录” | 节点有有效认证状态；不证明每条网络路径或业务服务可达 |
| “设备在线” | 必须说明是管控在线、传输可达，还是应用服务探测成功 |
| “透明转发” | 不解析业务 HTTP/2 / Protobuf；本机握手、授权和资源管理仍存在 |
| “独立项目” | 可以单独维护和被依赖；不是所有平台必需独立进程或安装第二个应用 |
| “共享代码” | 可以被其他应用复用；不是共享登录、节点状态目录或业务信任 |
| “支持 TCP” | 提供有序双向流；不自动重放 RPC、不替代文件续传或应用 TLS 校验 |
| “打洞成功” | 至少建立了直连路径；不说明持续吞吐或晚高峰质量 |
| “本机回环” | 无需经过物理网卡；不表示其他本机进程无法连接 |
| “同一 tailnet” | 仍受可见性与连接策略限制；不自动获得媒体访问权限 |

## 资料索引

核对日期：2026-11-11。以下是一手资料；API 页和 issue 后续可能变化。确定依赖后，在实现记录中补充对应版本、源码位置和实际结果，保留“文档说明”“问题报告”“本项目实测”的区别。

| 资料 | 用途与证据范围 |
| --- | --- |
| [tsnet 官方介绍](https://tailscale.com/docs/features/tsnet) | 内嵌节点用途与运行模型 |
| [tsnet Go API](https://pkg.go.dev/tailscale.com/tsnet) | Dial、Listen、LocalClient 与状态存储；不是 Flutter 包 |
| [本地客户端 API](https://pkg.go.dev/tailscale.com/client/local) | Status、WatchIPNBus、WhoIs；不需要宿主持有管理 API 令牌 |
| [PeerStatus](https://pkg.go.dev/tailscale.com/ipn/ipnstate#PeerStatus) | 解释 Online、Active 等字段，避免用节点状态替代业务在线 |
| [管控与数据面](https://tailscale.com/docs/concepts/control-data-planes) | 管控、数据传输和身份提供方的职责区分 |
| [管控暂时不可用](https://tailscale.com/docs/reference/coordination-server-down) | 已有通信可能继续，不能以控制故障直接清空身份 |
| [连接类型](https://tailscale.com/docs/reference/connection-types) | 直连、中继与连接质量分别验证 |
| [Grants](https://tailscale.com/docs/features/access-control/grants) | 网络访问策略，不能替代宿主业务配对 |
| [密钥到期](https://tailscale.com/docs/features/access-control/key-expiry) | 重新认证场景；不将登录成功描述为永久有效 |
| [libtailscale](https://github.com/tailscale/libtailscale) | C 库与静态 / 动态链接路线参考 |
| [libtailscale Windows 跟踪](https://github.com/tailscale/tailscale/issues/7649) | 平台封装问题线索，不是 Windows 必然不可实现的结论 |
| [Android tsnet 跟踪](https://github.com/tailscale/tailscale/issues/17311) | 网络接口权限问题报告，需在选定版本和设备上复现 |
| [Flutter packages 与 plugins](https://docs.flutter.dev/packages-and-plugins/developing-packages) | 平台分层、多 Engine 生命周期和原生封装 |
| [Dart gRPC 自定义连接器](https://pub.dev/documentation/grpc/latest/grpc/ClientTransportConnector-class.html) | 通用连接扩展的参考；latest 与 Tamayura 固定版本分别核对 |
| [连接器 channel](https://pub.dev/documentation/grpc/latest/grpc/ClientTransportConnectorChannel-class.html) | gRPC 适配器的候选接入接口 |
| [HTTP/2 字节流入口](https://pub.dev/documentation/http2/latest/transport/ClientTransportConnection/ClientTransportConnection.viaStreams.html) | 建立 HTTP/2 传输；不是自动提供 TLS 的承诺 |
| [gRPC HTTP/2 协议](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md) | 消息、响应和流式传输语义 |
| [Dart I/O 平台范围](https://api.dart.dev/dart-io/) | 原生 Socket 路线不直接适用于浏览器 |
| [Go TLS](https://pkg.go.dev/crypto/tls)、[Dart SecureSocket](https://api.dart.dev/dart-io/SecureSocket-class.html) | 推荐本机服务端认证方案的基础接口；具体会话证书固定仍须原型验证 |
| [Tailscale 主仓库许可证](https://github.com/tailscale/tailscale/blob/main/LICENSE) | 使用上游代码时保留相应许可及第三方声明 |

中国大陆可达性不能由以上架构说明保证。公开讨论可辅助选择测试场景，但真实验收必须分别测认证页面、官方管控、直连、中继和业务吞吐，并记录运营商组合、时段与是否使用辅助代理。当前没有本项目的大陆线路实测结果；具体记录要求见[验证计划](06-validation-and-roadmap.md)。
