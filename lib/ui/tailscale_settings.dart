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
            if (model.tailscaleNodeId != null) ...[
              const SizedBox(height: 8),
              Text(text.tailscaleLocalIdentity),
              SelectableText(
                '${model.deviceName}\n'
                '${model.tailscaleLocalDeviceId ?? ""}\n${model.tailscaleNodeId}',
              ),
            ],
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
            if (model.tailscaleAuthorizedDeviceIds.isNotEmpty) ...[
              const Divider(height: 24),
              Text(text.tailscaleAuthorized),
              for (final id in model.tailscaleAuthorizedDeviceIds)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    model.devices
                            .where((device) => device.id == id)
                            .firstOrNull
                            ?.name ??
                        id,
                  ),
                  trailing: TextButton(
                    key: Key('tailscale-revoke-$id'),
                    onPressed: enabled
                        ? () => model.revokeTailscaleDevice(id)
                        : null,
                    child: Text(text.tailscaleRevoke),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class TailscaleCandidates extends StatelessWidget {
  const TailscaleCandidates({super.key, required this.model});
  final TamayuraModel model;

  @override
  Widget build(BuildContext context) {
    final text = context.l10n;
    if (model.tailscaleCandidates.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          text.tailscaleCandidates,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final candidate in model.tailscaleCandidates)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    candidate.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  SelectableText('${candidate.deviceId}\n${candidate.nodeId}'),
                  if (candidate.replacesAssociation)
                    Text(
                      text.tailscaleReplacesNode,
                      key: Key('tailscale-replaces-${candidate.key}'),
                    )
                  else if (candidate.existingDevice)
                    Text(text.tailscaleExistingDevice),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: Key('tailscale-confirm-${candidate.key}'),
                    onPressed: model.tailscaleBusy
                        ? null
                        : () async {
                            if (await _confirm(
                              context,
                              text.tailscaleConfirm,
                              '${candidate.replacesAssociation ? text.tailscaleReplaceConfirmMessage : text.tailscaleConfirmMessage}'
                              '\n\n${candidate.name}\n'
                              '${candidate.deviceId}\n${candidate.nodeId}',
                            )) {
                              await model.confirmTailscaleDevice(candidate.key);
                            }
                          },
                    child: Text(text.tailscaleConfirm),
                  ),
                ],
              ),
            ),
          ),
      ],
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
