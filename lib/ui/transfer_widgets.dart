import 'package:flutter/material.dart';

import '../app/view_state.dart';
import 'desktop_layout.dart';

String transferLabel(TransferStatus status) => switch (status) {
  TransferStatus.queued => '等待下载',
  TransferStatus.downloading => '正在下载',
  TransferStatus.saving => '正在保存到接收目录',
  TransferStatus.completed => '已保存到本机',
  TransferStatus.failed => '下载失败',
  TransferStatus.cancelled => '已取消',
};

String formatMediaBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).ceil()} KB';
}

class TransferControls extends StatelessWidget {
  const TransferControls({
    super.key,
    required this.item,
    required this.transfer,
    required this.onDownload,
    required this.onCancel,
    required this.onShare,
    required this.onOpen,
    this.compact = false,
  });

  final MediaView item;
  final TransferView? transfer;
  final VoidCallback onDownload, onCancel, onShare, onOpen;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final current = transfer;
    final complete = current?.complete ?? false;
    final running = current?.running ?? false;
    final status = current?.status;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                complete
                    ? Icons.check_circle_outline_rounded
                    : status == TransferStatus.failed
                    ? Icons.error_outline_rounded
                    : status == TransferStatus.cancelled
                    ? Icons.pause_circle_outline_rounded
                    : Icons.downloading_rounded,
                size: 19,
                color: status == TransferStatus.failed
                    ? colors.error
                    : colors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status == null ? '原文件尚未下载' : transferLabel(status),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (running && status != TransferStatus.queued)
                Text(
                  '${((current!.progress.isFinite ? current.progress : 0).clamp(0, 1) * 100).round()}%',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
        if (running) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            borderRadius: BorderRadius.circular(4),
            minHeight: 5,
            value:
                status == TransferStatus.queued ||
                    status == TransferStatus.saving
                ? null
                : (current!.progress.isFinite ? current.progress : 0)
                      .clamp(0, 1)
                      .toDouble(),
          ),
          const SizedBox(height: 8),
          Text(
            current!.totalBytes > 0
                ? '${formatMediaBytes(current.receivedBytes)} / ${formatMediaBytes(current.totalBytes)}'
                : formatMediaBytes(item.size),
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          if (!compact)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                '可返回相册或切换应用，接收任务会继续进行。',
                style: TextStyle(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
        ],
        if (current?.error != null && status != TransferStatus.cancelled) ...[
          const SizedBox(height: 8),
          Text(
            current!.error!,
            key: Key('transfer-error-${item.key}'),
            style: TextStyle(fontSize: 12, height: 1.5, color: colors.error),
          ),
        ],
        if ((current?.attempt ?? 1) > 1)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              '第 ${current!.attempt} 次尝试',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (complete) ...[
              FilledButton.icon(
                key: Key('share-${item.key}'),
                onPressed: onShare,
                icon: Icon(
                  isWindowsDesktop
                      ? Icons.folder_open_rounded
                      : Icons.ios_share_rounded,
                  size: 18,
                ),
                label: Text(isWindowsDesktop ? '在文件夹中显示' : '分享'),
              ),
              OutlinedButton.icon(
                key: Key('open-${item.key}'),
                onPressed: onOpen,
                icon: Icon(
                  item.isVideo
                      ? Icons.play_arrow_rounded
                      : Icons.open_in_new_rounded,
                  size: 18,
                ),
                label: Text(item.isVideo ? '播放视频' : '用其他应用打开'),
              ),
            ] else if (running)
              OutlinedButton.icon(
                key: Key('cancel-${item.key}'),
                onPressed: onCancel,
                icon: const Icon(Icons.close_rounded, size: 17),
                label: const Text('取消下载'),
              )
            else
              FilledButton.icon(
                key: Key('retry-${item.key}'),
                onPressed: onDownload,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(
                  status == TransferStatus.failed
                      ? '重试下载'
                      : status == TransferStatus.cancelled
                      ? '重新下载'
                      : '下载原文件',
                ),
              ),
          ],
        ),
      ],
    );
  }
}
