import 'package:flutter/material.dart';

import '../app/view_state.dart';
import '../l10n/app_locale.dart';

class DeviceOrderDialog extends StatefulWidget {
  const DeviceOrderDialog({
    super.key,
    required this.devices,
    required this.onSave,
  });

  final List<DeviceView> devices;
  final Future<bool> Function(List<String> deviceIds) onSave;

  @override
  State<DeviceOrderDialog> createState() => _DeviceOrderDialogState();
}

class _DeviceOrderDialogState extends State<DeviceOrderDialog> {
  late final _devices = List<DeviceView>.of(widget.devices);
  bool _saving = false;
  String? _error;

  void _move(int from, int to) {
    if (_saving || from == to || to < 0 || to >= _devices.length) return;
    setState(() => _devices.insert(to, _devices.removeAt(from)));
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.onSave(
        _devices.map((device) => device.id).toList(),
      );
      if (!mounted) return;
      if (saved) {
        Navigator.of(context).pop();
      } else {
        setState(() => _error = context.l10n.deviceOrderSaveFailed);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.deviceOrderSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: ReorderableListView.builder(
                    key: const Key('device-order-list'),
                    shrinkWrap: true,
                    buildDefaultDragHandles: false,
                    itemCount: _devices.length,
                    onReorderItem: _move,
                    header: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.deviceOrderTitle,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.deviceOrderDescription,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      return Material(
                        key: ValueKey(device.id),
                        color: colors.surfaceContainerHigh,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              ReorderableDragStartListener(
                                key: Key('device-order-drag-${device.id}'),
                                index: index,
                                enabled: !_saving,
                                child: Tooltip(
                                  message: l10n.deviceOrderDrag(device.name),
                                  child: SizedBox(
                                    width: 40,
                                    height: 56,
                                    child: Icon(
                                      Icons.drag_handle_rounded,
                                      color: _saving
                                          ? colors.onSurface.withValues(
                                              alpha: .38,
                                            )
                                          : colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      device.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      device.online
                                          ? l10n.commonOnline
                                          : l10n.commonOffline,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                    Text(
                                      device.address,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: Key('device-order-up-${device.id}'),
                                    tooltip: l10n.deviceOrderMoveUp(
                                      device.name,
                                    ),
                                    onPressed: _saving || index == 0
                                        ? null
                                        : () => _move(index, index - 1),
                                    icon: const Icon(
                                      Icons.arrow_upward_rounded,
                                    ),
                                  ),
                                  IconButton(
                                    key: Key('device-order-down-${device.id}'),
                                    tooltip: l10n.deviceOrderMoveDown(
                                      device.name,
                                    ),
                                    onPressed:
                                        _saving || index == _devices.length - 1
                                        ? null
                                        : () => _move(index, index + 1),
                                    icon: const Icon(
                                      Icons.arrow_downward_rounded,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      key: const Key('device-order-error'),
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                const SizedBox(height: 16),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  overflowAlignment: OverflowBarAlignment.end,
                  spacing: 8,
                  overflowSpacing: 8,
                  children: [
                    TextButton(
                      key: const Key('device-order-cancel'),
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: Text(l10n.commonCancel),
                    ),
                    FilledButton(
                      key: const Key('device-order-save'),
                      onPressed: _saving ? null : _save,
                      child: Text(
                        _saving ? l10n.commonSaving : l10n.commonSave,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
