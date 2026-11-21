import 'package:material_ui/material_ui.dart';

import '../app/view_state.dart';
import '../l10n/app_locale.dart';
import 'app_icons.dart';

class TailscaleSettings extends StatelessWidget {
  const TailscaleSettings({super.key, required this.model});
  final TamayuraModel model;

  @override
  Widget build(BuildContext context) {
    final text = context.l10n;
    final state = switch (model.tailscaleState) {
      TailscaleConnectionState.signedOut => text.tailscaleSignedOut,
      TailscaleConnectionState.connecting => text.tailscaleConnecting,
      TailscaleConnectionState.needsLogin => text.tailscaleNeedsLogin,
      TailscaleConnectionState.needsApproval => text.tailscaleNeedsApproval,
      TailscaleConnectionState.connected => text.tailscaleConnected,
      TailscaleConnectionState.unavailable => text.tailscaleUnavailable,
    };
    final enabled = !model.loading && !model.tailscaleBusy;
    final diagnostics = model.tailscaleDiagnostics;
    final candidates = model.tailscaleCandidates;
    final authorized = Map.of(model.tailscaleAuthorizedDevices);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text.tailscaleTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(text.tailscaleDescription),
            const SizedBox(height: 12),
            Text(state, key: const Key('tailscale-status')),
            if (model.tailscaleControlDisconnected)
              Text(
                text.tailscaleControlDisconnected,
                key: const Key('tailscale-control-warning'),
              ),
            if (diagnostics != null) ...[
              const SizedBox(height: 8),
              Text(
                diagnostics.sharingReady
                    ? text.tailscaleSharingReady
                    : text.tailscaleSharingNotReady,
              ),
              if (diagnostics.visibleNodes case final count?) ...[
                Text(text.tailscaleVisibleNodes(count)),
                if (diagnostics.respondingNodes case final replies?)
                  Text(text.tailscaleRespondingNodes(replies))
                else
                  Text(text.tailscaleProbePending),
              ] else
                Text(text.tailscaleScanPending),
            ],
            if (model.tailscaleBusy) const LinearProgressIndicator(),
            if (model.tailscaleError != null) ...[
              const SizedBox(height: 8),
              Text(
                model.tailscaleError!,
                key: const Key('tailscale-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!model.tailscaleEnabled ||
                    model.tailscaleState ==
                        TailscaleConnectionState.signedOut ||
                    model.tailscaleState ==
                        TailscaleConnectionState.needsLogin ||
                    model.tailscaleState ==
                        TailscaleConnectionState.unavailable)
                  FilledButton.icon(
                    key: const Key('tailscale-login'),
                    onPressed: enabled
                        ? () async {
                            if (await _confirm(
                              context,
                              text.tailscaleLogin,
                              text.tailscaleDataNotice,
                            )) {
                              await model.loginTailscale();
                            }
                          }
                        : null,
                    icon: const Icon(AppIcons.connect),
                    label: Text(text.tailscaleLogin),
                  ),
                if (model.tailscaleCanOpenLogin)
                  OutlinedButton(
                    key: const Key('tailscale-open-login'),
                    onPressed: enabled ? model.openTailscaleLogin : null,
                    child: Text(text.tailscaleOpenLogin),
                  ),
                if (model.tailscaleEnabled) ...[
                  OutlinedButton(
                    key: const Key('tailscale-retry'),
                    onPressed: enabled ? model.retryTailscale : null,
                    child: Text(text.tailscaleRetry),
                  ),
                  TextButton(
                    key: const Key('tailscale-logout'),
                    onPressed: enabled
                        ? () async {
                            if (await _confirm(
                              context,
                              text.tailscaleLogout,
                              text.tailscaleLogoutMessage,
                            )) {
                              await model.logoutTailscale();
                            }
                          }
                        : null,
                    child: Text(text.tailscaleLogout),
                  ),
                ],
              ],
            ),
            if (candidates.isNotEmpty || authorized.isNotEmpty) ...[
              const Divider(height: 24),
              Text(
                text.tailscaleCandidates,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final candidate in candidates)
                _SharingDevice(
                  model: model,
                  name: candidate.name,
                  candidate: candidate,
                  // Re-registration offers a new node while the previous
                  // grant can still be revoked independently.
                  authorizedId: authorized.remove(candidate.deviceId) != null
                      ? candidate.deviceId
                      : null,
                  enabled: enabled,
                ),
              for (final device in authorized.entries)
                _SharingDevice(
                  model: model,
                  name: device.value,
                  authorizedId: device.key,
                  enabled: enabled,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SharingDevice extends StatelessWidget {
  const _SharingDevice({
    required this.model,
    required this.name,
    required this.enabled,
    this.candidate,
    this.authorizedId,
  });

  final TamayuraModel model;
  final String name;
  final bool enabled;
  final TailscaleDeviceView? candidate;
  final String? authorizedId;

  @override
  Widget build(BuildContext context) {
    final text = context.l10n;
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text(name),
          Wrap(
            spacing: 8,
            children: [
              if (candidate case final device?)
                OutlinedButton(
                  key: Key('tailscale-confirm-${device.key}'),
                  onPressed: enabled
                      ? () async {
                          final message = [
                            if (device.replacesAssociation)
                              text.tailscaleReplaceConfirmMessage
                            else ...[
                              text.tailscaleConfirmMessage,
                              if (device.existingDevice)
                                text.tailscaleExistingDevice,
                            ],
                            '${device.name}\n${device.deviceId}\n${device.nodeId}',
                          ].join('\n\n');
                          if (await _confirm(
                            context,
                            text.tailscaleConfirm,
                            message,
                          )) {
                            await model.confirmTailscaleDevice(device.key);
                          }
                        }
                      : null,
                  child: Text(text.tailscaleConfirm),
                ),
              if (authorizedId case final id?)
                TextButton(
                  key: Key('tailscale-revoke-$id'),
                  onPressed: enabled
                      ? () => model.revokeTailscaleDevice(id)
                      : null,
                  child: Text(text.tailscaleRevoke),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
) async {
  final text = context.l10n;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(text.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(text.commonConfirm),
            ),
          ],
        ),
      ) ??
      false;
}
