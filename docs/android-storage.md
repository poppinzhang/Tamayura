# Android 16 目录访问、发现与后台下载

## 存储与按需图片

最低系统为 Android 16（API 36）。共享和接收目录使用系统 Storage Access Framework (`ACTION_OPEN_DOCUMENT_TREE`) 选择，保存系统提供的持久 URI 授权。应用只访问被选中的目录及其子目录，不申请整个照片库或 `MANAGE_EXTERNAL_STORAGE`。系统选择器不允许选择存储根目录、Download 根目录以及 `Android/data`、`Android/obb`；建议选择 `DCIM/Camera` 或自行创建的接收子目录。[Android 共享文件访问文档](https://developer.android.com/training/data-storage/shared/documents-files)

扫描在线程池中递归枚举图片、视频的轻量元数据，不解码或携带缩略图。原生返回完整元数据列表，由 Dart 构造可分页同步的快照；大目录仍会消耗与文件数量成正比的元数据内存。缩略图通过独立的 `thumbnail(id)` 按需读取，最长边 256 像素、JPEG 格式。优先使用 `ContentResolver.loadThumbnail`；不可用时图片通过 `ImageDecoder` 定尺寸解码，视频使用缩放关键帧。个别媒体不能解码时返回空字节，由界面显示占位图。大小未知的文件不能安全分块，扫描时跳过。

扫描先按文档提供者的 MIME 类型筛选，只同步 `image/*` 和 `video/*`；MIME 缺失或为 `application/octet-stream` 时，按不区分大小写的文件扩展名推断类型。文本、JSON、XMP、`.nomedia`、音频及无法识别的文件直接跳过，不校验其名称或相对路径，也不打开文件读取大小、生成缩略图或加入共享映射。`.nomedia` 本身被忽略，不阻止扫描同目录中的照片和视频；子目录仍递归扫描，仅含非媒体文件的目录成功返回空媒体列表。

此前普通非媒体文件已有过滤，但名称必填与路径校验早于类型筛选；非媒体条目缺失名称或含反斜杠、控制字符等不支持的名称时，会提前抛错，导致共享快照不可用、对端同步失败。现在将类型筛选提前。媒体文件和子目录仍须通过名称与路径校验，但不合规、缺少名称、大小未知或打开描述符失败的单个媒体，以及无法列出的子目录只会被跳过，不再让整台设备停止共享。`SecurityException` 与扫描取消仍终止扫描；共享根目录无法列出时扫描失败。扫描结束前再次查询每个根目录文档：根目录在扫描期间被删除或提供者失效时扫描失败，不会把因此跳过的文件当作删除发布。

每次扫描开始先取消更早的扫描并移除不再共享的根目录，保留目录的旧映射在扫描期间继续服务，完整成功后才整体发布新映射；扫描失败撤销全部映射。文件 ID 是共享目录 UUID 与文档 ID 的 SHA-256 摘要，局域网协议仅包含共享目录名与根下相对路径，不包含本机文档 URI 或绝对路径。多个目录作为完整快照一起发布，文件读取分别核验所属树的授权。读取分块及缩略图时检查授权、共享代数以及该文件是否仍以相同内容发布，文件被替换或移除时返回 `SCAN_CANCELLED` 供对端重试。旧请求或已移除根目录的延迟授权错误不会撤销当前目录，接收目录授权错误也不影响有效的共享目录。

分块使用独立文件描述符执行 `pread`，单次最多 256 KiB，允许并发。仅提供管道的文档提供者退化为独立输入流跳读，速度可能下降；建议共享本机存储目录。

下载完的图片可通过 `readPreview(uri, maxDimension)` 预览：`ImageDecoder` 根据目标尺寸解码并处理图片方向，最长边不超过 2560 像素，返回最多 8 MiB 的 JPEG；不会将完整原图直接传入 Dart。预览为显示副本，接收目录中的原文件不变。

## 保存、打开和分享

下载分片保存在应用私有 `filesDir/transfer-staging`，可以在 Activity 销毁后继续使用。`saveDownload(sourcePaths, expectedSize, ...)` 按列表顺序直接将分片流式写入接收文件，不再生成完整合并暂存文件；只接受应用私有目录中的源文件，保存前和实际复制后均校验总大小。通过接收目录的持久授权逐级创建或复用「设备 / 共享根 / 子目录」，再创建新文档。Dart 持久化各层名称映射，区分同名设备和共享根；原生校验路径段，用进程级锁保护目录与文件创建，同名文件追加后缀另存，不覆盖已有文件。详见 [多目录共享与合集](多目录共享与合集.md)。

`transferSpace` 查询 `filesDir` 所在卷可用字节数。SAF 提供者的接收卷容量和是否与暂存位于同卷无法可靠判断，因此省略 `destinationAvailableBytes` 和 `sameVolume`，不把未知容量当成零。目录授权失败照常返回错误；空间预检查不能替代实际写入期间的错误处理。

复制过程每个分块及关闭输出后检查取消标记。失败或协作取消会尝试删除刚创建的文档；后台任务只有在 native I/O 已返回且旧引擎已销毁后才释放同任务的执行权限。`cancelTransfer` 的方法通道响应也等待该时点，使 Dart 在放弃任务并清理分片时不会与尚在执行的保存操作竞争。系统直接杀死整个进程时无法保证清理回调运行，接收目录可能残留未登记或未完成的文档。保存成功与 Dart 将 URI 写入 SQLite 之间也存在进程被杀的窗口，重试可能创建重复文件；当前没有跨文档提供者与 SQLite 的原子提交。

打开和分享前会在线程池中尝试只读打开 URI，确认文件存在且授权有效，失败则将错误返回 Dart 以清理过期下载记录。分享使用系统面板、`content://` URI 和临时只读授权，由用户选择目标应用。

## UIDT 后台下载

后台传输由 `BackgroundTransferService` 使用 Android 的 user-initiated data transfer（UIDT）JobScheduler 任务承载。用户在应用可见时发起任务，网络约束允许 Wi-Fi 或以太网，不要求互联网可用或网络已通过互联网验证。系统仍可能因约束变化、设备健康状态或进程回收停止任务。[Android UIDT 文档](https://developer.android.com/develop/background-work/background-tasks/uidt)

每个任务有独立的 headless `FlutterEngine`，自动注册 Flutter 插件，执行 `lib/main.dart` 中标记了 `@pragma('vm:entry-point')` 的 `backgroundTransferMain`。引擎属于 JobService，Activity 销毁不结束它。业务任务、分片进度和运行标识保存在 Dart 的 SQLite 数据库；native 仅持久保存 task ID 与 JobScheduler ID 的映射，并处理哈希碰撞。

Activity 直接调度下载，不请求或等待 `POST_NOTIFICATIONS`，也不以应用通知或媒体下载频道是否开启作为调度条件。未授予权限、拒绝通知或关闭频道时仍正常下载；应用内任务页继续显示进度、结果和重试入口，真实调度失败与目录授权错误照常返回。

任务启动时仍立即通过 `JobService.setNotification` 关联进度通知，再启动 Flutter 引擎。Android 要求 UIDT 在启动后及时提供通知，缺失会导致系统停止任务；通知栏是否展示由系统根据用户设置决定，关闭通知时系统任务管理器仍可能显示运行中的应用。通知允许时提供打开应用管理下载的入口，显示进度和结果。下载进度持续更新系统传输统计；任务停止后的普通 `NotificationManager.notify` 只在通知权限、应用通知和媒体下载频道均允许时调用。用户可在系统设置中允许通知。[JobService.setNotification 官方说明](https://developer.android.com/reference/android/app/job/JobService#setNotification(android.app.job.JobParameters,int,android.app.Notification,int))

系统停止回调会向 Dart 发出 `stop`，并给出约两秒保存状态和取消的时间。系统暂停返回可重试，用户取消不重试。Dart 回报对端暂时不可用（`complete` 带 `retry: true`）时以 `jobFinished(params, true)` 交由系统退避重排。引擎销毁后如仍有文件复制在退出，继续等待 I/O 返回；同 task 的立即重试只能在旧引擎和旧 I/O 都结束后重新提交，旧 `complete` 不能完成新任务。等待旧引擎退出期间的取消，也会让此前的延迟调度回调失效。

`scheduledTransferIds` 查询系统当前排队或执行的任务。应用重新打开时可据此识别 SQLite 中仍显示运行、但系统已无任务的中断记录。Android 系统任务管理器的停止操作可能直接终止进程且不调用 `onStopJob`，因此不能将停止回调作为唯一保存进度的时机。任务不会因本实现自动跨设备重启重建；用户可从应用中重试持久记录。

后台下载不会让对端设备的共享服务自动常驻。对端仍需运行应用并可通过局域网访问。

## 方法通道

`AndroidBridge` 使用 `tamayura/platform`：

| 方法 | 输入 | 返回 |
| --- | --- | --- |
| `pickDirectory` | 无 | `{uri, name}`；取消为 `null` |
| `validateSharedDirectory` | `uri, existingUris` | 确认不重复且无父子重叠 |
| `scanDirectoriesMetadata` | `directories: [{id, uri, name}]` | `[{id, name, mimeType, size, modifiedMs, sharedFolderId, sharedFolderName, relativePath}]` |
| `thumbnail` | `id` | 单张缩略图字节 |
| `clearSharedDirectory` | 无 | 撤销共享映射并取消旧扫描 |
| `readRange` | `id, offset, length` | 原始分块字节；最多 256 KiB |
| `readPreview` | `uri, maxDimension=2560` | 受限 JPEG 预览，最大 8 MiB |
| `saveDownload` | `sourcePaths, expectedSize, directoryUri, name, mimeType, directories` | 保存后的文档 URI |
| `transferSpace` | `directoryUri` | `{stagingAvailableBytes?}`；SAF 接收卷容量和卷关系未知 |
| `share` / `open` | `uri, mimeType` | 系统分享或外部查看 |
| `transferDirectory` | 无 | 持久下载暂存目录 |
| `temporaryDirectory` | 无 | 应用临时缓存目录 |
| `scheduleTransfer` | `taskId` | 直接发起系统 UIDT 任务，不请求通知权限 |
| `cancelTransfer` | `taskId` | 取消系统任务，等待旧 worker 和 native I/O 结束后返回 |
| `scheduledTransferIds` | 无 | 系统排队/执行的 task ID 列表 |
| `localInfo` | 无 | `{name, addresses}`，本机非回环 IPv4 地址 |
| `startDiscovery` | `id, name, port` | 注册并发现 DNS-SD 服务 |
| `stopDiscovery` | 无 | 停止发现，注销服务与服务信息回调 |

Headless 引擎的 `tamayura/platform` 仅开放 `transferDirectory`、`transferSpace` 和 `saveDownload`。其 `tamayura/background` 协议如下：

| 方向 / 方法 | 数据 | 作用 |
| --- | --- | --- |
| Dart → native `ready` | 无 | 返回 `{taskId}` |
| Dart → native `progress` | `{received, total, name}` | 更新通知与系统统计 |
| Dart → native `complete` | `{success, error?, cancelled?}` | Dart 完成数据库写入和关闭后结束任务 |
| native → Dart `stop` | `{reason, cancelled}` | 取消工作并保存可恢复状态 |

错误通过 `PlatformException` 返回，包括 `DIR_OVERLAP`、`DIR_RELATION_UNKNOWN`、`PERMISSION_LOST`、`FILE_NOT_FOUND`、`INVALID_ARGUMENT`、`NO_COMPATIBLE_APP`、`SCAN_CANCELLED`、`TRANSFER_SCHEDULE_FAILED`、`TRANSFER_CANCELLED`、`TRANSFER_STOPPED`、`PLATFORM_ERROR`。

## DNS-SD

服务类型 `_tamayura._tcp.`，TXT 包含 `id`、`name`、`version=3`。使用 `DiscoveryRequest` 和 `ServiceInfoCallback` 持续接收服务地址变化，不再使用一次性旧解析队列。所有回调在主线程执行，以会话代数屏蔽旧结果；退出时注销服务信息订阅。系统负责当前 NSD 使用场景的组播接收，应用不手动持有组播锁。[Android NsdManager 文档](https://developer.android.com/reference/android/net/nsd/NsdManager)

`tamayura/discovery` 事件为 `found`、`lost` 或 `error`。前两者包含 `id, name, host, port`；错误包含 `stage, code, message`。过滤自身 ID。路由器设备隔离或屏蔽组播仍会影响自动发现，可使用手动 IP 或二维码。

Manifest 声明网络权限、摄像头权限、`RUN_USER_INITIATED_JOBS` 和 `POST_NOTIFICATIONS`；JobService 使用 `BIND_JOB_SERVICE` 保护且不对外导出。

## 验证

- `test/platform/android_bridge_test.dart`：覆盖元数据与按需缩略图、64 位范围、权限错误、调度和取消、系统任务恢复查询、真实调度失败、持久暂存路径、受限预览与分享。
- 原生 `SharedCatalogTest` / `StoragePathsTest` / `TransferPolicyTest`：JVM 测试覆盖目录授权代数、超过旧规模的轻量目录、任务标识碰撞、运行排他与旧回调失效、等待期间取消、进度计算和预览尺寸边界。通过 `:app:testDebugUnitTest` 执行。
- 原生 `SafMediaStoreTest`：使用 Robolectric Android 16（API 36）的文档提供者游标调用实际扫描入口，覆盖混合媒体与非媒体、异常非媒体名称、未知大小不触发文件读取、MIME 扩展名推断、递归子目录、空媒体快照及真实媒体/目录/授权错误；需要 Java 21 或更新版本。
- 原生 `TransferNotificationTest`：在 Robolectric Android 16（API 36）上覆盖权限未授予、应用通知关闭、下载频道关闭与通知允许四种状态，验证真实 Activity 调度入口、无授权弹框、取消重试、系统调度失败和 JobService 通知关联；测试运行需要 Java 21 或更新版本。
- 这些测试不能替代系统 JobScheduler、文档提供者、通知权限和两台真机网络环境的验证。

设备验收：

1. 选择包含多个子目录、照片、大视频及 `.txt`、`.json`、`.xmp`、`.nomedia`、音频等非媒体文件的共享目录，确认两端只列出照片和视频、可正常下载；仅含非媒体文件时相册为空且同步成功。确认扫描不等待所有缩略图生成，滚动时按需出现缩略图。
2. 两台 Android 16+ 设备在同一 Wi-Fi 中相互发现，检查服务地址变更、断网、重新连接和手动连接。
3. 下载小图片及大于 50 MiB 的视频，与源文件比较内容哈希；图片预览和系统分享均可用。
4. 下载时离开或销毁 Activity，确认系统 JobService 仍在传输，允许通知时通知更新，重新进入页面可恢复进度。
5. 下载中断网后恢复，检查分片续传；取消后立即重试，检查旧引擎不会继续改写新任务。
6. 分别验证首次未授予通知权限、拒绝通知、关闭应用通知和禁用下载频道：不弹授权请求、不显示普通下载提醒、仍能完成下载且应用内进度正常；重新允许通知后正常显示提醒。撤销接收目录授权或删除已下载文件时仍应显示可恢复错误。
7. 系统任务管理器停止或进程被杀后重新打开应用，确认中断记录可重试，并检查接收目录是否存在需清理的未登记文档。
