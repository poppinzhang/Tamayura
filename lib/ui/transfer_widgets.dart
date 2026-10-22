import 'package:material_ui/material_ui.dart';

import '../app/view_state.dart';
import '../l10n/app_locale.dart';
import 'app_icons.dart';
import 'desktop_layout.dart';

String transferLabel(AppLocalizations l10n, TransferStatus status) =>
    switch (status) {
      TransferStatus.queued => l10n.transferQueued,
      TransferStatus.downloading => l10n.transferDownloading,
      TransferStatus.saving => l10n.transferSaving,
      TransferStatus.completed => l10n.transferCompleted,
      TransferStatus.failed => l10n.transferFailed,
      TransferStatus.cancelled => l10n.transferPaused,
      TransferStatus.discarded => l10n.transferDiscarded,
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
    required this.onDiscard,
    required this.onShare,
    required this.onOpen,
    this.compact = false,
  });

  final MediaView item;
  final TransferView? transfer;
  final VoidCallback onDownload, onCancel, onDiscard, onShare, onOpen;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = context.l10n;
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
                    ? AppIcons.success
                    : status == TransferStatus.failed
                    ? AppIcons.error
                    : status == TransferStatus.cancelled
                    ? AppIcons.paused
                    : AppIcons.downloads,
                size: 19,
                color: status == TransferStatus.failed
                    ? colors.error
                    : colors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status == null
                      ? l10n.transferNotDownloaded
                      : transferLabel(l10n, status),
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
                l10n.transferContinues,
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
        if (current != null && !complete && current.receivedBytes > 0)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              l10n.transferStaged(formatMediaBytes(current.receivedBytes)),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        if ((current?.attempt ?? 1) > 1)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              l10n.transferAttempt(current!.attempt),
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
                  revealsSavedFiles ? AppIcons.folder : AppIcons.share,
                  size: 18,
                ),
                label: Text(
                  revealsSavedFiles
                      ? l10n.transferShowInFolder
                      : l10n.commonShare,
                ),
              ),
              OutlinedButton.icon(
                key: Key('open-${item.key}'),
                onPressed: onOpen,
                icon: Icon(
                  item.isVideo ? AppIcons.play : AppIcons.open,
                  size: 18,
                ),
                label: Text(
                  item.isVideo ? l10n.transferPlayVideo : l10n.transferOpenWith,
                ),
              ),
            ] else if (running)
              OutlinedButton.icon(
                key: Key('cancel-${item.key}'),
                onPressed: onCancel,
                icon: const Icon(AppIcons.pause, size: 17),
                label: Text(l10n.transferPause),
              )
            else if (status != TransferStatus.discarded)
              FilledButton.icon(
                key: Key('retry-${item.key}'),
                onPressed: onDownload,
                icon: const Icon(AppIcons.download, size: 18),
                label: Text(
                  status == TransferStatus.failed
                      ? l10n.transferRetry
                      : status == TransferStatus.cancelled
                      ? l10n.transferResume
                      : l10n.transferDownloadOriginal,
                ),
              ),
            if (current != null && !complete)
              TextButton.icon(
                key: Key('discard-${item.key}'),
                onPressed: onDiscard,
                icon: const Icon(AppIcons.delete, size: 18),
                label: Text(
                  running
                      ? l10n.transferCancelAndDelete
                      : l10n.transferDeleteTask,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
