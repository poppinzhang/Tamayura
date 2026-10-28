# Android 16+ 实现说明

项目最低支持 **Android 16（API 36）**。Gradle 的 minSdk、targetSdk、compileSdk 均为 36；低于此版本无法安装。Flutter 仍承担界面、SQLite 和 gRPC，后续桌面/iOS 平台可提供各自适配器。

## 版本基线与视觉

删除 Android 8/旧 NSD 和旧视频缩略图分支，使用 ServiceInfoCallback 获取服务与地址变化，现代 ImageDecoder/视频缩略图 API。文件提供者只提供管道时的 seek 回退仍保留：这是存储提供者能力差异，不是旧系统兼容。

UI 使用 Flutter Hero、InteractiveViewer 与 PredictiveBack 页面转场。双击与双指放大后禁止下滑退出；未放大时可下滑返回。初始显示缓存缩略图，下载完成后读取本地图片：Android 按最长边 2560 解码并压缩，Flutter 再限制显示解码尺寸，避免将原始大图全部读入内存。视频提供系统播放器入口。

这些 Flutter 视觉效果并非 Android 16 专属；提高最低版本主要减少平台分支并统一行为，不保证所有硬件上的特效性能一致。

## 后台传输

用户在可见 Activity 点击照片，先持久保存下载任务，再直接提交 JobScheduler 的用户发起数据传输任务（UIDT），不请求或等待通知权限。未授予 `POST_NOTIFICATIONS`、关闭应用通知或关闭媒体下载频道均不阻止下载；调度失败、目录授权失效等实际错误仍明确显示并允许重试。Manifest 保留 `RUN_USER_INITIATED_JOBS`、`POST_NOTIFICATIONS` 与 JobService 声明，用户可在系统设置中手动允许下载提醒。

UIDT 服务仍须调用 `JobService.setNotification`，由系统依据用户设置控制通知栏展示；不能因通知关闭而省略此调用，否则系统可能停止任务。关闭通知时不显示普通下载提醒，系统任务管理器仍可能显示运行中的应用。任务停止后的普通通知仅在权限和通知频道均允许时发送。[JobService.setNotification 官方说明](https://developer.android.com/reference/android/app/job/JobService#setNotification(android.app.job.JobParameters,int,android.app.Notification,int))

任务要求 Wi-Fi 或以太网，但不要求网络能访问互联网。JobService 创建独立 FlutterEngine，运行 `backgroundTransferMain`；不会依赖相册 Activity 存活。`tamayura/background` 的 ready/progress/complete/stop 通道用于任务身份、通知和中断。

1.0.1 显式移除 `NetworkRequest.Builder` 默认的 `NET_CAPABILITY_NOT_VPN` 条件，允许基于 Wi-Fi / 以太网的 VPN 或 TUN。Android 的 VPN 网络会包含底层网络的 transport；只解除“非 VPN”限制，仍保留 Wi-Fi / 以太网条件，不单独添加 `TRANSPORT_VPN`，因此纯蜂窝和纯蜂窝 VPN 仍不匹配。旧条件可能导致相册同步正常、下载一直等待：前台同步直接建立 gRPC 连接，下载则先经过 JobScheduler 的网络匹配。此修复不修改系统路由，代理仍须允许局域网设备互通。[Android 网络能力说明](https://developer.android.com/reference/android/net/NetworkCapabilities#NET_CAPABILITY_NOT_VPN)、[VPN 与底层 transport](https://developer.android.com/develop/connectivity/network-ops/reading-network-state)。

`TransferNotificationTest` 从真实调度入口取得 `JobInfo.requiredNetwork`，覆盖普通及 VPN 上的 Wi-Fi / 以太网、无互联网验证的局域网，以及拒绝蜂窝、蜂窝 VPN、无底层局域网的 VPN 和无网络。开发阶段原条件在 VPN 局域网匹配断言失败，修复后 Android 应用原生 147 项、Flutter 网络与传输相关 57 项回归通过。这是网络条件与应用行为回归，不代替本次发布提交的完整检查或真机 VPN / TUN 下的任务启动及双向原文件传输验收；发布准备时完整测试与打包仍待完成，实际结果见 [1.0.1 发布记录](releases/1.0.1.md)。

SQLite 的 `tamayura_transfers.db` 保存媒体与设备快照、目标目录、状态、已下载字节、次数、错误、已保存 URI 和运行令牌。UI 与 worker 使用独立数据库连接；运行令牌条件写入可阻止旧任务覆盖新尝试。界面前台轮询状态，恢复时将已无系统任务的未完成记录标为可重试。

超过 50 MiB 分成四个区间，每个分片保存在应用私有 filesDir；长度本身就是续传位置。manifest 校验设备、文件、大小与修改时间，改变后清除旧分片。每个范围流 30 秒收不到数据即判定停滞并重连；对端暂时不可用时，连续三次没有新字节的尝试后交由 JobScheduler 退避重排，最长自动重试 30 分钟，收到字节即重新计时；文件删除、大小变化等不可恢复错误保留分片并显示重试。详见 [传输恢复](传输恢复.md)。每次恢复先核对对端设备 ID，避免 IP 地址被其他设备复用。

手动取消先写数据库，再停止系统任务。系统停止通知 worker 尽快保存状态；原生端给退出留出时间，且对同一 taskId 串行管理引擎与保存操作，避免旧任务与重试同时写文件。保存中断会尝试删除外部目录半成品。成功保存并登记后清理私有分片。

## 边界与验收

UIDT 不是无限后台保活。网络断开、资源不足或用户停止可中断任务，已持久保存的分片可重试；强行停止后不会擅自自动启动。来源端可在设置中开启「后台共享」，由 `connectedDevice` 前台服务维持独立于页面的引擎与 gRPC 服务；关闭时释放唤醒锁，退后台停止共享网络。长时间息屏仍受电池优化及厂商限制影响，详见 [后台共享](后台共享.md)。

外部文档提供者与 SQLite 不能共享事务：文件成功保存、数据库登记前若进程被强杀，可能留下未登记的完整副本，重试可能另存。未完成分片保留供续传，清除应用数据会一并删除。

验收必须包含：16+ 双机，首次未授予通知权限、通知拒绝、应用通知关闭和媒体下载频道关闭时均不弹授权请求且能完成下载、应用内进度正常；通知允许时正常显示进度和结果。还需验证接收退后台和锁屏、下载中断 Wi-Fi 后恢复、系统停止后显式重试、四路大文件续传、取消后立即重试、外部目录权限撤销/空间不足，来源端锁屏、切后台或重新扫描后自动续传，以及来源端超过 30 分钟不可达时可理解的失败提示。

依据：[Android UIDT 官方说明](https://developer.android.com/develop/background-work/background-tasks/uidt)、[Android 16 行为变更](https://developer.android.com/about/versions/16/behavior-changes-16)。
