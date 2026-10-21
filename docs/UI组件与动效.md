# UI 组件与动效

## 选型与可行性

本方案用于共享 Flutter 界面，已随 0.9.6 发布，实际验证与验收边界见 [0.9.6 发布记录](releases/0.9.6.md)。现有 Material 3、中性色主题、手机底部导航和桌面侧边导航继续使用，不涉及网络协议、数据库或原生平台能力的迁移。

| 职责 | 采用方案 | 约束与理由 |
| --- | --- | --- |
| UI 组件 | 官方 `material_ui` `^1.8.0`，Material 3 | `AppTheme` 启用 `useMaterial3`，主题、标准按钮、导航、菜单、弹窗及触摸区域统一使用独立 Material 包。 |
| 应用图标 | `lucide_icons_flutter` 4.0.1 | Lucide 社区 Flutter 实现；字体随应用离线打包，不依赖网络或平台插件。业务代码通过 `AppIcons` 的语义常量使用。 |
| 日常动效 | `flutter_animate` 4.5.2 | 负责同步提示收起、快速滚动提示渐隐及预览拖动回弹，不给媒体网格逐项增加动画。 |
| 页面过渡 | 官方 `animations` `^3.0.0` | 与 `material_ui` 使用同一套 Material 类型；标签页使用 Fade Through，非 Android 路由使用水平 Shared Axis，Android 保留预测返回实现。 |

这些依赖的 Flutter 界面可在项目目标平台使用，但不能据此声称 Linux、iOS 原生工程或发布已经实现。依赖的具体版本由 `pubspec.lock` 固定；项目继续使用 Flutter 3.47.6 / Dart 3.13.5。

`material_ui` 是 Flutter 官方从 SDK 中拆分出的 Material 实现，提供 Material 3 组件及其主题与本地化能力。项目将自有界面、相关模型中的 Material 类型和界面测试统一迁移到这个包；`animations` 3.0.0 同样已迁移到 `material_ui`，因此可以直接使用同一套主题和页面路由类型。[官方迁移说明](https://pub.dev/packages/material_ui)、[animations 更新记录](https://pub.dev/packages/animations/changelog)。

其他依赖来源：[Lucide 包目录](https://lucide.dev/packages)、[Flutter 图标包](https://pub.dev/packages/lucide_icons_flutter)、[flutter_animate](https://pub.dev/packages/flutter_animate)。

## 导入与本地化规范

- 手写的应用与测试代码使用 `package:material_ui/material_ui.dart` 导入 `MaterialApp`、`Theme`、`ThemeData`、`ThemeMode`、`ColorScheme`、Material 组件及页面过渡类型；不再从 `package:flutter/material.dart` 导入这些类型。同名类型来自不同库，混用会导致类型不匹配，或组件无法找到对应的主题与本地化对象。
- 仅需基础组件、渲染、服务或测试工具时，继续使用 `package:flutter/widgets.dart`、`rendering.dart`、`services.dart` 和 `package:flutter_test/flutter_test.dart` 等相应入口。Lucide 图标映射仍使用基础 `IconData`，不需要改写为另一套图标实现。
- 应用和测试中的 `MaterialApp.localizationsDelegates` 统一使用 `AppLocale.localizationsDelegates`，由应用文案代理与 `material_ui` 导出的 `GlobalMaterialLocalizations.delegates` 组合。后者同时提供匹配的 Material、Cupertino 与基础 Widgets 本地化，详见 [多语言](多语言.md#flutter-实现)。
- `flutter gen-l10n` 生成的 `AppLocalizations.localizationsDelegates` 仍引用 SDK 的旧 Material 本地化，不能直接作为新 `MaterialApp` 的代理列表。保留生成器输出，通过手写的 `AppLocale` 统一组合代理；不手改生成文件，也不在每个页面单独维护代理列表。

## 实现

- `lib/ui/app_icons.dart` 集中映射图标，使用 `static const IconData` 和 `@staticIconProvider`，支持 Release 字体裁剪。相同图标可服务多个相近语义；导航选中态由 Material 指示器、颜色和标签表达。主题同时覆盖默认返回、关闭按钮图标。组件内部的勾选标记等仍由 Material 绘制；系统托盘和启动图标不属于这套业务图标。
- `AppTheme` 保留已有控件尺寸、圆角与配色，并将 `IconButtonThemeData.variant` 明确设为 `StyleVariant.material3`，不在迁移中启用 Material 3 Expressive 外观。
- `lib/ui/app_motion.dart` 集中读取系统减少动画和无障碍导航标志。`AppTabTransition` 始终保留一棵 `IndexedStack`，仅在选中标签改变时播放 220 ms 进入过渡；进度、语言和主题更新不重播。不会并行挂载两个相册列表，也不会丢失标签状态或让一个滚动控制器连接两份页面。
- 路由继续使用 `MaterialPageRoute`，由 `PageTransitionsTheme` 统一设置；扫码返回值、返回栈、详情和许可证页面沿用同一导航机制。Android 的 `PredictiveBackPageTransitionsBuilder` 自带系统手势观察器，保留它以支持取消或提交预测返回；关闭新版新增的过渡快照优化，让相机画面和下载进度在切页时继续实时绘制，不复制框架私有手势实现。
- 同步通知继续由 `SyncNotices` 按同步会话维护状态、5 秒停留时间和 300 ms 收起进度。`SyncNoticeTransition` 用 adapter 将进度传给 `flutter_animate`，挂载和卸载时成对管理监听；筛选设备或切换标签不会重置截止时间。
- 快速滚动保留 3 秒停留和 300 ms 淡入淡出。预览拖动直接跟随手指，未达到关闭阈值时用 180 ms 回弹；新拖动可在当前可见位置接管回弹。

## 主菜单双击回到顶部

相册、设备、设置三个主菜单在手机底部导航、桌面展开或收起的侧栏，以及窄桌面窗口的底部导航中均支持双击回顶。第一次点击立即切换页面并保留原滚动位置；在 Flutter 的 `kDoubleTapTimeout`（300 ms）内再次点击同一菜单，将该页滚动到顶部。点击不同菜单、超过时间窗口或使用桌面切页快捷键后，重新开始计数；双击完成后也重新计数。

`_HomeState` 的 `_onNavigationSelected` 处理导航激活序列，沿用 Material 导航的完整按钮点击区域、焦点和语义，不额外拦截单击。三个页面各自持有并释放独立的 `ScrollController`，相册复用已有控制器，设备和设置保留原 `PageStorageKey`。回顶使用 300 ms 的 `easeOutCubic` 滚动动画，开启减少动画或无障碍导航时直接跳到 `minScrollExtent`。页面尚未挂载或已经在顶部时安全忽略回顶；计时器在页面销毁时取消。

双击只改变目标页的纵向滚动位置，保留当前合集、设备筛选、显示模式及其他页面位置，不触发刷新或原文件下载；现有切页时退出本地文件选择、删除处理中禁止切页的规则继续适用。合集总览、合集内网格和移动端索引网格共用同一相册控制器。

## 减少动画与交互边界

启用 `MediaQuery.disableAnimations` 或 `accessibleNavigation` 后，标签和普通路由不播放装饰过渡，关闭相册与预览之间的 Hero 飞行，跳过提示收起和预览回弹。`AppHero` 在页面内容内部设置 `HeroMode`，确保路由的 Hero 遍历能识别该开关。Android 系统返回的手势观察与用户直接操控仍保留。运行时改变设置保留页面状态；新发起的媒体页面切换遵循最新开关。

同步结果和滚动提示仍分别停留 5 秒、3 秒；减少动画不应让信息来不及阅读。预览拖动、缩放、返回、工具提示、按钮语义与原操作保持一致。Material 组件自身的交互反馈仍遵循框架行为，不强行替换系统文件选择器、原生菜单或平台通知。

## 验证

- `app_icons_test.dart` 检查字体离线资源与下载状态图标。
- `app_motion_test.dart` 覆盖标签状态、滚动控制器、路由结果、减少动画、Android 预测返回及切页期间持续重绘。
- `main_navigation_scroll_test.dart` 覆盖三个主菜单回顶、单击和双击判定、页面位置保留、桌面与手机导航、减少动画及未挂载页面。
- `material_localization_test.dart` 覆盖中、日、英 Material 控件、菜单、弹窗与无障碍文案；`language_ui_test.dart` 覆盖实际应用的语言切换与布局，`theme_test.dart` 保留主题对比度和 Material 3 约束。
- `sync_notice_ui_test.dart` 覆盖停留、收起、筛选、会话身份变化、减少动画切换和卸载。
- `album_fast_scroll_ui_test.dart`、`media_preview_motion_test.dart` 覆盖提示计时、重复刷新、拖动、回弹中断和减少动画。

公共检查仍按 AGENTS 执行，完整发布验证结果记录在 [0.9.6 发布记录](releases/0.9.6.md)。自动化行为检查不能代替三平台真实设备上的视觉流畅度、系统手势或屏幕阅读器验收。
