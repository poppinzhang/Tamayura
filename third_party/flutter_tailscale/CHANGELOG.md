# Changelog

## unstaged

### Implementation — 2026-11-15

- 新增可复用 `flutter_tailscale` 包和 Go tsnet 原生核心，固定 Tailscale 1.104.7、Go 1.27.4 与 Dart gRPC 4.2.0。
- 实现可选官方登录、私有节点恢复、作用域化 peer 引用、会话轮换、多 Engine 所有者和退出清理；Android 初始化与 Engine 销毁通过宿主登记和 JNI 清理处理竞态。
- 实现固定目标租约、证书固定 TLS + CONNECT、WhoIs 来源允许名单、入站双向 TLS 和现有连接撤销。
- 新增 Android 网络接口与切网适配、桌面继承管道和 Android FFI 控制、按平台构建及第三方许可证收集。
- 第三方许可证收集显式使用 UTF-8 解析 Go 输出、读取许可和写入声明，兼容 Windows 非 UTF-8 系统区域设置。
- 新增 gRPC 传输适配、可识别的证书/身份/授权错误原因及自动化验证；22 项 Dart 检查覆盖所有 RPC 流模式、取消/期限/重连、真实辅助进程所有权和鉴权边界。
- 修复服务撤销先等待原生响应的问题：先关闭本机 mTLS 监听及应用流，阻止迟到握手交付，再等待原生撤销；补充回归验证。
- 禁用上游 logtail 缓冲与上传，避免认证 URL 进入日志；macOS 用户态节点保留宿主路由，修复物理网卡绑定绕过宿主网络路径。
- 当前采用有界快照轮询和 NDJSON 控制协议，尚未实现设计草案中的有序事件、通用取消协议、iOS、Web 或 Headscale。
- 真实官方认证、内嵌节点互联网/DERP 和 Android 蜂窝/后台验收仍待完成；没有执行发布。

### Documentation — 2026-11-11

- 建立 Flutter-Tailscale 独立组件的中英文入口和七份详细设计文档。
- 定义 Go 核心、Flutter 插件及宿主业务的责任边界，首期接入官方 Tailscale 管控，Headscale 留待后续。
- 补齐 API 草案、节点身份与会话、控制通信、本机入口鉴权、双向 TCP 转发及 gRPC 适配设计。
- 记录各平台运行和打包约束、Tamayura 接入要求、验证矩阵、阶段门槛与待决事项。
- 本次仅新增文档，没有实现代码、依赖、构建配置、运行测试或发布产物。
