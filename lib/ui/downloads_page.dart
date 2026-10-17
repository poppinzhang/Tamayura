import 'package:flutter/material.dart';

import '../app/view_state.dart';
import 'media_preview.dart';
import 'desktop_layout.dart';
import 'transfer_widgets.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.model});
  final TamayuraModel model;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('任务操作未完成，请重试。')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final tasks = widget.model.transfers.entries.toList().reversed.toList()
        ..sort(
          (a, b) =>
              (b.value.running ? 1 : 0).compareTo(a.value.running ? 1 : 0),
        );
      final active = tasks.where((entry) => entry.value.running).length;
      return Scaffold(
        key: const Key('downloads-page'),
        appBar: AppBar(title: const Text('下载任务')),
        body: SafeArea(
          child: DesktopContent(
            child: tasks.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 38,
                            backgroundColor: colors.surfaceContainerHighest,
                            child: Icon(
                              Icons.download_for_offline_outlined,
                              size: 34,
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            '下一张心动的照片，在路上',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '轻点相册中的照片或视频，即可在这里查看下载进度。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 18),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('返回相册'),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    key: const PageStorageKey('downloads-list'),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                    itemCount: tasks.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                active == 0 ? '每一份，都有着落。' : '$active 个任务正在进行',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                isWindowsDesktop
                                    ? '关闭窗口后仍可继续接收，从系统托盘可重新打开。请保持电脑唤醒，并与来源设备处于同一局域网；退出或睡眠中断后可重试。'
                                    : isMacDesktop
                                    ? '关闭窗口后仍可继续接收，从菜单栏或 Dock 可重新打开。请保持 Mac 唤醒，并与来源设备处于同一局域网；退出或睡眠中断后可重试。'
                                    : '接收可在后台继续。来源设备需要保持玉响运行，并与这台设备处于同一局域网。',
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  height: 1.6,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      final entry = tasks[index - 1];
                      final transfer = entry.value;
                      final item =
                          transfer.item ??
                          widget.model.media
                              .where((item) => item.key == entry.key)
                              .firstOrNull;
                      return Container(
                        key: Key('task-${entry.key}'),
                        padding: const EdgeInsets.all(17),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: colors.outlineVariant),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: item == null
                                  ? null
                                  : () => Navigator.of(context).push<void>(
                                      MaterialPageRoute(
                                        builder: (_) => MediaPreviewPage(
                                          model: widget.model,
                                          item: item,
                                        ),
                                      ),
                                    ),
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 15),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: SizedBox(
                                        width: 52,
                                        height: 52,
                                        child:
                                            item != null &&
                                                item.thumbnail.isNotEmpty
                                            ? Image.memory(
                                                item.thumbnail,
                                                fit: BoxFit.cover,
                                                cacheWidth: 150,
                                                errorBuilder: (_, _, _) =>
                                                    _placeholder(item.isVideo),
                                              )
                                            : _placeholder(
                                                item?.isVideo ?? false,
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item?.name ?? '媒体文件',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          if (item != null) ...[
                                            const SizedBox(height: 5),
                                            Text(
                                              formatMediaBytes(item.size),
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: colors.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    if (item != null)
                                      Icon(
                                        Icons.chevron_right_rounded,
                                        color: colors.onSurfaceVariant,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            if (item != null)
                              TransferControls(
                                item: item,
                                transfer: transfer,
                                compact: true,
                                onDownload: () =>
                                    _run(() => widget.model.download(item)),
                                onCancel: () => _run(
                                  () => widget.model.cancelDownload(entry.key),
                                ),
                                onDiscard: () => _run(
                                  () => widget.model.discardDownload(entry.key),
                                ),
                                onShare: () =>
                                    _run(() => widget.model.share(item)),
                                onOpen: () =>
                                    _run(() => widget.model.open(item)),
                              )
                            else
                              Text(
                                transferLabel(transfer.status),
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      );
    },
  );

  Widget _placeholder(bool video) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Icon(
      video ? Icons.videocam_outlined : Icons.photo_outlined,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
