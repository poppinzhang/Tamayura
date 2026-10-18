import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/view_state.dart';
import '../app/endpoint.dart';
import '../l10n/app_locale.dart';
import 'about_page.dart';
import 'album_image.dart';
import 'album_fast_scroll.dart';
import 'album_scroll_geometry.dart';
import 'app_theme.dart';
import 'device_order_dialog.dart';
import 'downloads_page.dart';
import 'desktop_layout.dart';
import 'media_preview.dart';
import 'sync_notices.dart';
import 'update_page.dart';

class TamayuraApp extends StatelessWidget {
  const TamayuraApp({super.key, required this.model});

  final TamayuraModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      onGenerateTitle: (context) => context.l10n.appTitle,
      locale: model.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: model.themeMode,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: Theme.of(context).appBarTheme.systemOverlayStyle!,
        child: child!,
      ),
      home: _Home(model: model),
    ),
  );
}

class _Home extends StatefulWidget {
  const _Home({required this.model});
  final TamayuraModel model;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> with TickerProviderStateMixin {
  int _tab = 0;
  bool _connecting = false;
  final _albumScroll = ScrollController();
  late SyncNotices _syncNotices;
  AlbumScrollGeometry? _albumGridGeometry;
  bool _requestingMore = false;
  bool _loadMoreFailed = false;
  int _albumPageGeneration = 0;
  bool _selectingLocal = false;
  bool _deletingLocal = false;
  final Set<String> _selectedLocal = {};
  final Map<String, MediaView> _selectedLocalItems = {};
  bool _approvalDialogOpen = false;
  TamayuraModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _albumScroll.addListener(_onAlbumScroll);
    _syncNotices = SyncNotices(model: model, vsync: this);
    model.addListener(_promptSyncApproval);
    _promptSyncApproval();
  }

  @override
  void didUpdateWidget(_Home oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != model) {
      oldWidget.model.removeListener(_promptSyncApproval);
      model.addListener(_promptSyncApproval);
      _syncNotices.dispose();
      _syncNotices = SyncNotices(model: model, vsync: this);
      _promptSyncApproval();
    }
  }

  @override
  void dispose() {
    model.removeListener(_promptSyncApproval);
    _syncNotices.dispose();
    _albumScroll.dispose();
    super.dispose();
  }

  void _onAlbumScroll() {
    if (_tab == 0 &&
        model.selectedCollectionKey != null &&
        !(isMobile && model.mediaScrollEntries.isNotEmpty) &&
        _albumScroll.position.extentAfter < 450 &&
        model.hasMoreMedia &&
        !model.loadingMoreMedia &&
        !model.mediaSortOrderChanging &&
        !_requestingMore &&
        !_loadMoreFailed &&
        model.error == null) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    if (_requestingMore ||
        model.loadingMoreMedia ||
        model.mediaSortOrderChanging ||
        !model.hasMoreMedia) {
      return;
    }
    final generation = _albumPageGeneration;
    setState(() {
      _requestingMore = true;
      _loadMoreFailed = false;
    });
    try {
      await model.loadMoreMedia();
    } catch (_) {
      if (mounted && generation == _albumPageGeneration) {
        setState(() => _loadMoreFailed = true);
      }
    } finally {
      if (mounted && generation == _albumPageGeneration) {
        setState(() => _requestingMore = false);
      }
    }
  }

  void _resetAlbumPaging() => setState(() {
    _albumPageGeneration++;
    _requestingMore = false;
    _loadMoreFailed = false;
  });

  Future<void> _selectDevice(String? id) async {
    if (_deletingLocal) return;
    _clearLocalSelection();
    _resetAlbumPaging();
    await _run(() => model.selectDevice(id));
    if (mounted && _albumScroll.hasClients) _albumScroll.jumpTo(0);
  }

  Future<void> _selectCollection(String? key) async {
    if (_deletingLocal) return;
    _clearLocalSelection();
    _resetAlbumPaging();
    await _run(() => model.selectCollection(key));
    if (mounted && _albumScroll.hasClients) _albumScroll.jumpTo(0);
  }

  Future<void> _setMediaSortOrder(MediaSortOrder order) async {
    if (_deletingLocal ||
        model.mediaSortOrderChanging ||
        order == model.mediaSortOrder) {
      return;
    }
    _clearLocalSelection();
    _resetAlbumPaging();
    await _run(() => model.setMediaSortOrder(order));
    if (mounted && _albumScroll.hasClients) _albumScroll.jumpTo(0);
  }

  Widget _albumSortButton() {
    final enabled = !_deletingLocal && !model.mediaSortOrderChanging;
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<MediaSortOrder>(
      key: const Key('album-sort'),
      enabled: enabled,
      tooltip: context.l10n.albumSortTooltip,
      initialValue: model.mediaSortOrder,
      onSelected: _setMediaSortOrder,
      itemBuilder: (_) => [
        for (final order in MediaSortOrder.values)
          CheckedPopupMenuItem(
            key: Key('album-sort-${order.name}'),
            value: order,
            checked: order == model.mediaSortOrder,
            child: Text(_mediaSortLabel(order)),
          ),
      ],
      child: Semantics(
        button: true,
        enabled: enabled,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: colors.outline),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: IconTheme(
              data: IconThemeData(
                size: 18,
                color: enabled ? colors.primary : colors.onSurfaceVariant,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort_rounded),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      model.mediaSortOrderChanging
                          ? context.l10n.albumSorting
                          : context.l10n.albumSortLabel(
                              _mediaSortLabel(model.mediaSortOrder),
                            ),
                      style: TextStyle(
                        color: enabled
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more_rounded),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _mediaSortLabel(MediaSortOrder order) => switch (order) {
    MediaSortOrder.nameAscending => context.l10n.albumSortNameAscending,
    MediaSortOrder.nameDescending => context.l10n.albumSortNameDescending,
    MediaSortOrder.dateAscending => context.l10n.albumSortDateAscending,
    MediaSortOrder.dateDescending => context.l10n.albumSortDateDescending,
  };

  void _preview(MediaView item) {
    final transfer = model.transfers[item.key];
    if (transfer?.complete != true && transfer?.running != true) {
      unawaited(_run(() => model.download(item)));
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MediaPreviewPage(model: model, item: item),
      ),
    );
  }

  void _clearLocalSelection() => setState(() {
    _selectingLocal = false;
    _selectedLocal.clear();
    _selectedLocalItems.clear();
  });

  void _toggleLocalSelection(MediaView item) {
    if (_deletingLocal ||
        model.mediaSortOrderChanging ||
        model.transfers[item.key]?.complete != true) {
      return;
    }
    setState(() {
      _selectingLocal = true;
      if (_selectedLocal.add(item.key)) {
        _selectedLocalItems[item.key] = item;
      } else {
        _selectedLocal.remove(item.key);
        _selectedLocalItems.remove(item.key);
      }
    });
  }

  void _pruneLocalSelection() {
    if (_deletingLocal) return;
    final keys = isMobile && model.mediaScrollEntries.isNotEmpty
        ? model.mediaScrollEntries.map((item) => item.key)
        : model.media.map((item) => item.key);
    final savedKeys = keys
        .where((key) => model.transfers[key]?.complete == true)
        .toSet();
    _selectedLocal.retainAll(savedKeys);
    _selectedLocalItems.removeWhere((key, _) => !_selectedLocal.contains(key));
  }

  Future<void> _deleteSelectedLocalFiles() async {
    if (_deletingLocal) return;
    final selected = _selectedLocalItems.values
        .where(
          (item) =>
              _selectedLocal.contains(item.key) &&
              model.transfers[item.key]?.complete == true,
        )
        .toList();
    if (selected.isEmpty) return;
    setState(() => _deletingLocal = true);
    var deleted = 0;
    for (final item in selected) {
      try {
        if (await model.deleteLocalFile(item)) {
          deleted++;
          _selectedLocal.remove(item.key);
        }
      } catch (_) {
        // Keep failed selections so the user can retry the remaining files.
      }
    }
    if (!mounted) return;
    setState(() {
      _deletingLocal = false;
      if (_selectedLocal.isEmpty) _selectingLocal = false;
    });
    final failed = selected.length - deleted;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? context.l10n.albumLocalDeleted(deleted)
              : context.l10n.albumLocalDeletePartial(deleted, failed),
        ),
      ),
    );
  }

  Widget _localSelectionBar() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
    child: Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(context.l10n.albumSelectedCount(_selectedLocal.length)),
        FilledButton.icon(
          key: const Key('confirm-delete-local'),
          onPressed: _deletingLocal || _selectedLocal.isEmpty
              ? null
              : _deleteSelectedLocalFiles,
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(
            _deletingLocal
                ? context.l10n.albumDeleting
                : isMobile
                ? context.l10n.albumDeleteLocalFiles
                : context.l10n.commonConfirm,
          ),
        ),
        TextButton(
          key: const Key('cancel-delete-local'),
          onPressed: _deletingLocal ? null : _clearLocalSelection,
          child: Text(context.l10n.commonCancel),
        ),
      ],
    ),
  );

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.homeActionFailed)));
    }
  }

  Future<void> _connect(String address) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    await _run(() => model.connect(address));
    if (mounted) setState(() => _connecting = false);
  }

  Future<void> _manualConnect() async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    if (address != null && mounted) await _connect(address);
  }

  Future<void> _editAutoSyncInterval() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AutoSyncIntervalDialog(
        initialMinutes: model.autoSyncIntervalMinutes,
        onSave: (minutes) async {
          var saved = false;
          await _run(() async {
            await model.setAutoSyncIntervalMinutes(minutes);
            saved = model.autoSyncIntervalMinutes == minutes;
          });
          return saved;
        },
      ),
    );
  }

  Future<void> _editDeviceOrder() async {
    if (model.deviceOrderSaving || model.devices.length < 2) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DeviceOrderDialog(
        devices: model.devices,
        onSave: model.reorderDevices,
      ),
    );
  }

  Future<void> _scan() async {
    final address = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _ScannerPage()));
    if (address != null && mounted) await _connect(address);
  }

  void _showQr() {
    if (model.addresses.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (context) => _DeviceQrDialog(
        name: model.deviceName,
        addresses: model.addresses,
        port: model.port,
      ),
    );
  }

  void _changeTab(int tab) {
    if (_deletingLocal) return;
    _clearLocalSelection();
    setState(() => _tab = tab);
  }

  Widget _desktopNavigation(bool extended) => NavigationRail(
    key: const Key('desktop-navigation'),
    extended: extended,
    minExtendedWidth: 188,
    selectedIndex: _tab,
    onDestinationSelected: _changeTab,
    labelType: extended
        ? NavigationRailLabelType.none
        : NavigationRailLabelType.all,
    leading: const SizedBox(height: 12),
    destinations: [
      NavigationRailDestination(
        icon: const Icon(Icons.photo_library_outlined, key: Key('album-tab')),
        selectedIcon: const Icon(
          Icons.photo_library_rounded,
          key: Key('album-tab'),
        ),
        label: Text(context.l10n.navAlbum),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.devices_outlined, key: Key('devices-tab')),
        selectedIcon: const Icon(
          Icons.devices_rounded,
          key: Key('devices-tab'),
        ),
        label: Text(context.l10n.navDevices),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.tune_rounded, key: Key('settings-tab')),
        label: Text(context.l10n.navSettings),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([model, _syncNotices]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        _pruneLocalSelection();
        final desktopNavigation = isDesktop && constraints.maxWidth >= 800;
        return CallbackShortcuts(
          bindings: isDesktop
              ? {
                  SingleActivator(
                    LogicalKeyboardKey.digit1,
                    meta: isMacDesktop,
                    control: isWindowsDesktop,
                  ): () =>
                      _changeTab(0),
                  SingleActivator(
                    LogicalKeyboardKey.digit2,
                    meta: isMacDesktop,
                    control: isWindowsDesktop,
                  ): () =>
                      _changeTab(1),
                  SingleActivator(
                    LogicalKeyboardKey.digit3,
                    meta: isMacDesktop,
                    control: isWindowsDesktop,
                  ): () =>
                      _changeTab(2),
                  SingleActivator(
                    LogicalKeyboardKey.comma,
                    meta: isMacDesktop,
                    control: isWindowsDesktop,
                  ): () =>
                      _changeTab(2),
                  SingleActivator(
                    LogicalKeyboardKey.keyR,
                    meta: isMacDesktop,
                    control: isWindowsDesktop,
                  ): () {
                    if (!model.busy) unawaited(_run(model.refresh));
                  },
                }
              : const {},
          child: Focus(
            autofocus: isDesktop,
            child: PopScope(
              canPop:
                  !_selectingLocal &&
                  (_tab != 0 || model.selectedCollectionKey == null),
              onPopInvokedWithResult: (didPop, _) {
                if (didPop || _deletingLocal) return;
                if (_selectingLocal) {
                  _clearLocalSelection();
                } else {
                  unawaited(_selectCollection(null));
                }
              },
              child: Scaffold(
                appBar: AppBar(
                  titleSpacing: 22,
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.blur_circular_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        size: 28,
                      ),
                      SizedBox(width: 9),
                      Flexible(
                        child: Text(
                          'Tamayura',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (context.l10n.appLocalName.isNotEmpty) ...[
                        SizedBox(width: 8),
                        Text(
                          context.l10n.appLocalName,
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  actions: [
                    IconButton(
                      key: const Key('downloads-entry'),
                      tooltip: context.l10n.homeDownloadsTooltip,
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => DownloadsPage(model: model),
                        ),
                      ),
                      icon: Badge(
                        isLabelVisible: model.transfers.values.any(
                          (task) => task.running,
                        ),
                        child: const Icon(Icons.downloading_rounded),
                      ),
                    ),
                    IconButton(
                      key: const Key('refresh'),
                      tooltip: context.l10n.homeRefreshTooltip,
                      onPressed: model.busy ? null : () => _run(model.refresh),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                body: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      if (desktopNavigation) ...[
                        _desktopNavigation(constraints.maxWidth >= 1100),
                        const VerticalDivider(width: 1),
                      ],
                      Expanded(
                        child: Column(
                          children: [
                            if (model.busy)
                              const LinearProgressIndicator(minHeight: 2),
                            if (model.error != null)
                              _ErrorNotice(
                                message: model.error!,
                                onDismiss: model.clearError,
                                onRetry: model.busy
                                    ? null
                                    : () => _run(model.refresh),
                              ),
                            if (_tab == 0 && _selectingLocal)
                              _localSelectionBar(),
                            Expanded(
                              child:
                                  model.loading &&
                                      !(_tab == 2 &&
                                          model.backgroundSharingEnabled &&
                                          model.backgroundSharingStarting)
                                  ? Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const CircularProgressIndicator(),
                                          const SizedBox(height: 20),
                                          Text(context.l10n.homeOpening),
                                        ],
                                      ),
                                    )
                                  : IndexedStack(
                                      index: _tab,
                                      children: [
                                        DesktopContent(
                                          maxWidth: 1200,
                                          child: _album(),
                                        ),
                                        DesktopContent(child: _devices()),
                                        DesktopContent(child: _settings()),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                bottomNavigationBar: desktopNavigation
                    ? null
                    : NavigationBar(
                        selectedIndex: _tab,
                        onDestinationSelected: _changeTab,
                        destinations: [
                          NavigationDestination(
                            key: const Key('album-tab'),
                            icon: const Icon(Icons.photo_library_outlined),
                            selectedIcon: const Icon(
                              Icons.photo_library_rounded,
                            ),
                            label: context.l10n.navAlbum,
                          ),
                          NavigationDestination(
                            key: const Key('devices-tab'),
                            icon: const Icon(Icons.devices_outlined),
                            selectedIcon: const Icon(Icons.devices_rounded),
                            label: context.l10n.navDevices,
                          ),
                          NavigationDestination(
                            key: const Key('settings-tab'),
                            icon: const Icon(Icons.tune_rounded),
                            label: context.l10n.navSettings,
                          ),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _album() {
    final media = model.media;
    final devices = model.devices;
    final collections = model.collections;
    final browsingCollection = model.selectedCollectionKey != null;
    final scrollEntries = model.mediaScrollEntries;
    final virtualGrid =
        isMobile && browsingCollection && scrollEntries.isNotEmpty;
    final itemCount = virtualGrid ? scrollEntries.length : media.length;
    final collection = collections
        .where((item) => item.key == model.selectedCollectionKey)
        .firstOrNull;
    final syncDeviceId =
        collection?.deviceId ??
        model.selectedCollectionKey?.split('/').first ??
        model.selectedDeviceId;
    final syncProgress = model.syncProgress
        .where((item) => syncDeviceId == null || item.peerId == syncDeviceId)
        .toList();
    final syncing = syncProgress.any(
      (item) =>
          item.phase == SyncPhase.connecting ||
          item.phase == SyncPhase.receiving ||
          item.phase == SyncPhase.committing,
    );
    final syncFailed = syncProgress.any(
      (item) => item.phase == SyncPhase.failed,
    );
    final scrollView = CustomScrollView(
      key: const PageStorageKey('album-scroll'),
      controller: _albumScroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.albumHeadline,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.albumSubtitle,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 22),
                if (model.sharedFolders.isEmpty || model.downloadFolder == null)
                  _setupCard(),
                if (devices.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _filterChip(null, context.l10n.albumAllDevices, null),
                        for (final device in devices)
                          _filterChip(device.id, device.name, device.online),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                for (final notice in _syncNotices.visible.where(
                  (notice) =>
                      syncDeviceId == null ||
                      notice.progress.peerId == syncDeviceId,
                ))
                  SizeTransition(
                    key: ObjectKey(notice),
                    sizeFactor: notice.animation,
                    alignment: Alignment.topCenter,
                    child: FadeTransition(
                      key: Key('sync-notice-fade-${notice.progress.peerId}'),
                      opacity: notice.animation,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _SyncProgressCard(
                          progress: notice.progress,
                          onDismiss: notice.dismiss,
                          onRetry: model.busy
                              ? null
                              : () => _run(
                                  () => model.retrySync(notice.progress.peerId),
                                ),
                        ),
                      ),
                    ),
                  ),
                if (browsingCollection) ...[
                  TextButton.icon(
                    key: const Key('back-to-collections'),
                    onPressed: () => _selectCollection(null),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: Text(context.l10n.albumAllCollections),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    collection?.sharedFolderName ??
                        context.l10n.albumSharedCollectionFallback,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _albumSortButton(),
                        if (!isMobile && !_selectingLocal)
                          OutlinedButton.icon(
                            key: const Key('delete-local-files'),
                            onPressed:
                                !model.mediaSortOrderChanging &&
                                    media.any(
                                      (item) =>
                                          model.transfers[item.key]?.complete ==
                                          true,
                                    )
                                ? () => setState(() => _selectingLocal = true)
                                : null,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: Text(context.l10n.albumDeleteLocalFiles),
                          ),
                      ],
                    ),
                  ),
                ],
                if (!browsingCollection && collections.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      context.l10n.albumCollectionCount(collections.length),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                if (browsingCollection && media.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.l10n.albumMomentCount(
                              model.totalMediaCount,
                            ),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Flexible(
                          child: Text(
                            _selectingLocal
                                ? context.l10n.albumSelectSavedHint
                                : context.l10n.albumTapToDownloadHint,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (browsingCollection ? itemCount == 0 : collections.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 36, 28, 40),
              child: _EmptyState(
                icon: Icons.photo_library_outlined,
                title: syncing
                    ? context.l10n.albumReceivingTitle
                    : syncFailed
                    ? context.l10n.albumSyncIncompleteTitle
                    : devices.isEmpty
                    ? context.l10n.albumNoDevicesTitle
                    : browsingCollection
                    ? context.l10n.albumEmptyCollectionTitle
                    : context.l10n.albumNoCollectionsTitle,
                description: syncing
                    ? context.l10n.albumReceivingDescription
                    : syncFailed
                    ? context.l10n.albumSyncIncompleteDescription
                    : devices.isEmpty
                    ? context.l10n.albumNoDevicesDescription
                    : isDesktop
                    ? context.l10n.albumNoMediaDesktopDescription
                    : context.l10n.albumNoMediaMobileDescription,
                action: syncing || syncFailed
                    ? null
                    : TextButton.icon(
                        onPressed: () => setState(() => _tab = 1),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(context.l10n.albumConnectDevice),
                      ),
              ),
            ),
          )
        else if (!browsingCollection)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final count = (constraints.crossAxisExtent / 190)
                    .floor()
                    .clamp(2, 5)
                    .toInt();
                final textScale = MediaQuery.textScalerOf(context).scale(1);
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 12,
                    mainAxisExtent:
                        constraints.crossAxisExtent / count + 96 * textScale,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final item = collections[index];
                    final device = devices
                        .where((device) => device.id == item.deviceId)
                        .firstOrNull;
                    return _CollectionCard(
                      collection: item,
                      deviceName:
                          device?.name ?? context.l10n.rememberedDeviceFallback,
                      onTap: () => _selectCollection(item.key),
                    );
                  }, childCount: collections.length),
                );
              },
            ),
          )
        else
          SliverPadding(
            padding: model.albumDetailedMode
                ? const EdgeInsets.fromLTRB(18, 0, 18, 24)
                : const EdgeInsets.fromLTRB(2, 0, 2, 24),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final detailed = model.albumDetailedMode;
                final count = detailed
                    ? (constraints.crossAxisExtent / 175)
                          .floor()
                          .clamp(2, 5)
                          .toInt()
                    : (constraints.crossAxisExtent / 96)
                          .round()
                          .clamp(3, 12)
                          .toInt();
                final textScale = MediaQuery.textScalerOf(context).scale(1);
                final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: count,
                  mainAxisSpacing: detailed ? 14 : 2,
                  crossAxisSpacing: detailed ? 12 : 2,
                  childAspectRatio: 1,
                  mainAxisExtent: detailed
                      ? constraints.crossAxisExtent / count + 90 * textScale
                      : null,
                );
                final tileExtent = detailed
                    ? constraints.crossAxisExtent / count + 90 * textScale
                    : (constraints.crossAxisExtent - (count - 1) * 2) / count;
                _albumGridGeometry = AlbumScrollGeometry(
                  scrollOffset: constraints.precedingScrollExtent,
                  columns: count,
                  tileExtent: tileExtent,
                  rowStride: tileExtent + (detailed ? 14 : 2),
                  itemCount: itemCount,
                );
                return SliverGrid(
                  key: const Key('album-media-grid'),
                  gridDelegate: gridDelegate,
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final item = virtualGrid
                        ? model.mediaAtScrollIndex(index)
                        : media[index];
                    if (item == null) {
                      return _albumPlaceholder(index);
                    }
                    final device = devices
                        .where((device) => device.id == item.deviceId)
                        .firstOrNull;
                    return _MediaCard(
                      model: model,
                      detailed: detailed,
                      item: item,
                      deviceName:
                          device?.name ?? context.l10n.rememberedDeviceFallback,
                      online: device?.online ?? false,
                      transfer: model.transfers[item.key],
                      selecting: _selectingLocal,
                      selected: _selectedLocal.contains(item.key),
                      selectionEnabled: !_deletingLocal,
                      onSelect: () => _toggleLocalSelection(item),
                      onLongPress: isMobile && !_selectingLocal
                          ? () => _toggleLocalSelection(item)
                          : null,
                      onPreview: () => _preview(item),
                      onDownload: () => _run(() => model.download(item)),
                      onShare: () => _run(() => model.share(item)),
                    );
                  }, childCount: itemCount),
                );
              },
            ),
          ),
        if (browsingCollection &&
            !virtualGrid &&
            (model.hasMoreMedia ||
                model.loadingMoreMedia ||
                _requestingMore ||
                _loadMoreFailed))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 26),
              child: Column(
                children: [
                  if (_loadMoreFailed)
                    Text(
                      context.l10n.albumLoadMoreFailed,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (model.loadingMoreMedia || _requestingMore)
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Text(context.l10n.albumLoadingMore),
                        ],
                      ),
                    )
                  else
                    TextButton.icon(
                      key: const Key('load-more-media'),
                      onPressed: _loadMore,
                      icon: const Icon(Icons.expand_more_rounded),
                      label: Text(
                        _loadMoreFailed
                            ? context.l10n.albumRetryLoad
                            : context.l10n.albumLoadMore,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
    if (!isMobile || !browsingCollection) return scrollView;
    return AlbumFastScroll(
      key: const Key('album-fast-scroll'),
      controller: _albumScroll,
      geometry: () => _albumGridGeometry,
      entries: virtualGrid
          ? scrollEntries
          : [
              for (final item in media)
                MediaScrollEntry(
                  id: item.id,
                  deviceId: item.deviceId,
                  name: item.name,
                  modified: item.modified,
                ),
            ],
      sortOrder: model.mediaSortOrder,
      identity: (model.selectedCollectionKey, model.mediaSortOrder),
      active: _tab == 0 && !model.mediaSortOrderChanging,
      onVisibleRange: virtualGrid
          ? (first, last) =>
                unawaited(_run(() => model.ensureMediaScrollRange(first, last)))
          : null,
      child: scrollView,
    );
  }

  Widget _albumPlaceholder(int index) => ColoredBox(
    key: ValueKey('album-placeholder-$index'),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(
      child: model.error == null
          ? Icon(
              Icons.image_outlined,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              semanticLabel: context.l10n.albumLoadingThumbnail,
            )
          : IconButton(
              tooltip: context.l10n.albumRetryThumbnail,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () =>
                  _run(() => model.ensureMediaScrollRange(index, index)),
            ),
    ),
  );

  Widget _filterChip(String? id, String name, bool? online) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(name),
      selected: model.selectedDeviceId == id,
      showCheckmark: false,
      avatar: online == null
          ? const Icon(Icons.grid_view_rounded, size: 16)
          : Icon(
              Icons.circle,
              size: 8,
              color: online
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
      onSelected: (_) => _selectDevice(id),
    ),
  );

  Widget _setupCard() => Container(
    margin: const EdgeInsets.only(bottom: 22),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.folder_open_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.setupTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.setupDescription,
          style: const TextStyle(height: 1.5),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (model.sharedFolders.isEmpty)
              FilledButton.tonalIcon(
                key: const Key('setup-share'),
                onPressed: model.busy
                    ? null
                    : () => _run(model.chooseSharedFolder),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(context.l10n.setupShareFolder),
              ),
            if (model.downloadFolder == null)
              FilledButton.icon(
                key: const Key('setup-download'),
                onPressed: model.busy
                    ? null
                    : () => _run(model.chooseDownloadFolder),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(context.l10n.setupDownloadFolder),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _deviceCard(DeviceView device) {
    final colors = Theme.of(context).colorScheme;
    final forgetting = model.forgettingDeviceIds.contains(device.id);
    final l10n = context.l10n;
    final syncStatus = switch (device.syncApproval) {
      PeerSyncApproval.approved => l10n.deviceLastSuccessfulSync(
        _formatSuccessfulSync(l10n, device.lastSuccessfulSync),
      ),
      PeerSyncApproval.pending => l10n.devicePendingApproval,
      PeerSyncApproval.declined => l10n.deviceSyncDeclined,
    };
    return _SurfaceCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            key: Key('device-${device.id}'),
            contentPadding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
            leading: CircleAvatar(
              backgroundColor: colors.surfaceContainerHighest,
              child: Icon(
                Icons.devices_rounded,
                color: device.online ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
            title: Text(
              device.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${device.online ? l10n.commonOnline : l10n.deviceOfflineCached}'
              '\n${device.address}\n$syncStatus',
              style: const TextStyle(height: 1.6, fontSize: 12),
            ),
            isThreeLine: true,
            trailing: PopupMenuButton<_DeviceAction>(
              key: Key('device-menu-${device.id}'),
              enabled: !forgetting,
              tooltip: l10n.deviceActions,
              icon: forgetting
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.more_vert_rounded),
              onSelected: (action) => switch (action) {
                _DeviceAction.enableSync => _enableDeviceSync(device),
                _DeviceAction.forget => _forgetDevice(device),
              },
              itemBuilder: (_) => [
                if (!device.syncEnabled)
                  PopupMenuItem(
                    key: Key('device-enable-sync-${device.id}'),
                    value: _DeviceAction.enableSync,
                    child: Text(l10n.deviceEnableAlbumSync),
                  ),
                PopupMenuItem(
                  key: Key('device-forget-${device.id}'),
                  value: _DeviceAction.forget,
                  child: Text(context.l10n.deviceForget),
                ),
              ],
            ),
            onTap: () {
              _selectDevice(device.id);
              setState(() => _tab = 0);
            },
          ),
          if (!device.syncEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(70, 0, 14, 14),
              child: FilledButton.tonalIcon(
                key: Key('device-start-sync-${device.id}'),
                onPressed: forgetting ? null : () => _enableDeviceSync(device),
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: Text(l10n.deviceStartSync),
              ),
            ),
        ],
      ),
    );
  }

  void _enableDeviceSync(DeviceView device) =>
      unawaited(_run(() => model.setDeviceSyncEnabled(device.id, true)));

  Future<void> _forgetDevice(DeviceView device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ForgetDeviceDialog(device: device),
    );
    if (confirmed != true || !mounted) return;
    var forgotten = false;
    await _run(() async {
      forgotten = await model.forgetDevice(device.id);
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          forgotten
              ? context.l10n.deviceForgotten(device.name)
              : model.error ?? context.l10n.deviceForgetFailed,
        ),
      ),
    );
  }

  /// Offer each newly discovered device once. Dismissing leaves it pending;
  /// the device page still offers to enable synchronization.
  void _promptSyncApproval() {
    if (_approvalDialogOpen || !mounted) return;
    final request = model.syncApprovalRequests.firstOrNull;
    if (request == null) return;
    _approvalDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _approvalDialogOpen = false;
        return;
      }
      final enabled = await showDialog<bool>(
        context: context,
        builder: (_) => _SyncApprovalDialog(device: request),
      );
      _approvalDialogOpen = false;
      if (!mounted) return;
      if (enabled == null) {
        model.dismissSyncApproval(request.id);
      } else {
        // The decision is saved first; a started sync reports its own progress.
        unawaited(_run(() => model.setDeviceSyncEnabled(request.id, enabled)));
      }
      _promptSyncApproval();
    });
  }

  Widget _devices() => ListView(
    key: const PageStorageKey('devices-scroll'),
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(22, 20, 22, 30),
    children: [
      _PageHeading(
        title: context.l10n.devicesTitle,
        subtitle: context.l10n.devicesSubtitle,
      ),
      const SizedBox(height: 22),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.wifi_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 22,
                ),
                SizedBox(width: 8),
                Flexible(
                  child: Text(
                    context.l10n.devicesThisDevice,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              model.deviceName,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 23,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              model.addresses.isEmpty
                  ? context.l10n.devicesNoAddress
                  : model.addresses
                        .map((address) => '$address:${model.port}')
                        .join('\n'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: model.addresses.isEmpty || model.port <= 0
                  ? null
                  : _showQr,
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                disabledForegroundColor: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .38),
                side: BorderSide(color: Theme.of(context).colorScheme.outline),
              ),
              icon: const Icon(Icons.qr_code_rounded, size: 18),
              label: Text(context.l10n.devicesShowQr),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            key: const Key('connect-manual'),
            onPressed: _connecting || model.busy ? null : _manualConnect,
            icon: const Icon(Icons.add_link_rounded, size: 20),
            label: Text(context.l10n.devicesConnectByIp),
          ),
          if (!isWindowsDesktop)
            OutlinedButton.icon(
              onPressed: _connecting || model.busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
              label: Text(context.l10n.devicesScan),
            ),
        ],
      ),
      if (_connecting) ...[
        const SizedBox(height: 16),
        const LinearProgressIndicator(),
        const SizedBox(height: 6),
        Text(
          context.l10n.devicesConnecting,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
      const SizedBox(height: 30),
      Row(
        children: [
          Expanded(
            child: Text(
              context.l10n.devicesRemembered,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            context.l10n.devicesOnlineCount(
              model.devices.where((device) => device.online).length,
            ),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      if (model.devices.length > 1)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('edit-device-order'),
            onPressed: model.deviceOrderSaving ? null : _editDeviceOrder,
            icon: const Icon(Icons.swap_vert_rounded, size: 20),
            label: Text(context.l10n.devicesReorder),
          ),
        ),
      const SizedBox(height: 12),
      if (model.devices.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: _EmptyState(
            icon: Icons.radar_rounded,
            title: context.l10n.devicesEmptyTitle,
            description: context.l10n.devicesEmptyDescription,
          ),
        ),
      for (final device in model.devices) _deviceCard(device),
      const SizedBox(height: 12),
      Text(
        isWindowsDesktop
            ? context.l10n.devicesFooterWindows
            : isMacDesktop
            ? context.l10n.devicesFooterMac
            : context.l10n.devicesFooterMobile,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.6,
          fontSize: 12,
        ),
      ),
    ],
  );

  String _languageLabel(AppLanguage language) => language == AppLanguage.system
      ? context.l10n.settingsLanguageSystem
      : language.nativeName;

  Widget _languageCard() {
    final l10n = context.l10n;
    final enabled = !model.loading && !model.languageSaving;
    // The language actually shown, also when following the system.
    final shown = AppLanguage.parse(model.locale.languageCode).nativeName;
    return _SurfaceCard(
      child: PopupMenuButton<AppLanguage>(
        key: const Key('language-selector'),
        enabled: enabled,
        tooltip: l10n.settingsLanguage,
        initialValue: model.language,
        onSelected: (language) => _run(() => model.setLanguage(language)),
        itemBuilder: (_) => [
          for (final language in AppLanguage.values)
            CheckedPopupMenuItem(
              key: Key('language-${language.name}'),
              value: language,
              checked: language == model.language,
              child: Text(_languageLabel(language)),
            ),
        ],
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 10,
          ),
          enabled: enabled,
          leading: Icon(
            Icons.translate_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(l10n.settingsLanguage),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              model.languageSaving
                  ? l10n.settingsLanguageSaving
                  : model.language == AppLanguage.system
                  ? l10n.settingsLanguageSystemDescription(shown)
                  : l10n.settingsLanguageFixedDescription(shown),
              key: const Key('language-status'),
              style: const TextStyle(height: 1.6),
            ),
          ),
          trailing: const Icon(Icons.expand_more_rounded),
        ),
      ),
    );
  }

  Widget _settings() => ListView(
    key: const PageStorageKey('settings-scroll'),
    padding: const EdgeInsets.fromLTRB(22, 20, 22, 30),
    children: [
      _PageHeading(
        title: context.l10n.settingsTitle,
        subtitle: context.l10n.settingsSubtitle,
      ),
      const SizedBox(height: 26),
      _SectionLabel(context.l10n.settingsAppearance),
      _SurfaceCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.settingsThemeMode,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, constraints) {
                  final vertical =
                      constraints.maxWidth <
                      300 * MediaQuery.textScalerOf(context).scale(1);
                  return SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      key: const Key('theme-mode-selector'),
                      style: SegmentedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      direction: vertical ? Axis.vertical : Axis.horizontal,
                      // A scrolling settings page has unbounded vertical space.
                      expandedInsets: vertical ? null : EdgeInsets.zero,
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text(
                            context.l10n.settingsThemeSystem,
                            maxLines: 1,
                          ),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text(
                            context.l10n.settingsThemeLight,
                            maxLines: 1,
                          ),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text(
                            context.l10n.settingsThemeDark,
                            maxLines: 1,
                          ),
                        ),
                      ],
                      selected: {model.themeMode},
                      onSelectionChanged: model.loading || model.themeModeSaving
                          ? null
                          : (selection) => _run(
                              () => model.setThemeMode(selection.single),
                            ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Text(
                model.themeModeSaving
                    ? context.l10n.settingsThemeSaving
                    : model.themeMode == ThemeMode.system
                    ? context.l10n.settingsThemeSystemDescription
                    : model.themeMode == ThemeMode.light
                    ? context.l10n.settingsThemeLightDescription
                    : context.l10n.settingsThemeDarkDescription,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      _languageCard(),
      const SizedBox(height: 28),
      _SectionLabel(context.l10n.settingsAlbum),
      _SurfaceCard(
        child: SwitchListTile(
          key: const Key('album-detailed-mode'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 10,
          ),
          title: Text(context.l10n.settingsDetailedMode),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              model.albumDetailedModeSaving
                  ? context.l10n.settingsDetailedModeSaving
                  : context.l10n.settingsDetailedModeDescription,
              style: const TextStyle(height: 1.6),
            ),
          ),
          value: model.albumDetailedMode,
          onChanged: model.loading || model.albumDetailedModeSaving
              ? null
              : (enabled) => _run(() => model.setAlbumDetailedMode(enabled)),
        ),
      ),
      const SizedBox(height: 28),
      _SectionLabel(context.l10n.settingsSync),
      _SurfaceCard(
        child: ListTile(
          key: const Key('auto-sync-interval'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 10,
          ),
          title: Text(context.l10n.settingsAutoSyncInterval),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              model.autoSyncIntervalSaving
                  ? context.l10n.settingsAutoSyncSaving
                  : context.l10n.settingsAutoSyncDescription(
                      model.autoSyncIntervalMinutes,
                    ),
              style: const TextStyle(height: 1.6),
            ),
          ),
          trailing: const Icon(Icons.edit_outlined),
          enabled: !model.loading && !model.autoSyncIntervalSaving,
          onTap: model.loading || model.autoSyncIntervalSaving
              ? null
              : _editAutoSyncInterval,
        ),
      ),
      const SizedBox(height: 28),
      _SectionLabel(context.l10n.settingsFilesStorage),
      _SurfaceCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.settingsSharedFolders,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.settingsSharedFoldersDescription,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
              if (model.sharedFolders.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(context.l10n.settingsSharedFoldersEmpty),
                ),
              for (final folder in model.sharedFolders)
                ListTile(
                  key: Key('shared-folder-${folder.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_shared_outlined),
                  title: Text(folder.name),
                  subtitle: Text(
                    folder.uri,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    key: Key('remove-shared-folder-${folder.id}'),
                    tooltip: context.l10n.settingsRemoveSharedFolder(
                      folder.name,
                    ),
                    onPressed: model.loading || model.busy
                        ? null
                        : () => _run(() => model.removeSharedFolder(folder.id)),
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const Key('add-shared-folder'),
                onPressed: model.loading || model.busy
                    ? null
                    : () => _run(model.chooseSharedFolder),
                icon: const Icon(Icons.add_rounded),
                label: Text(context.l10n.settingsAddSharedFolder),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      _SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('background-sharing-switch'),
              contentPadding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
              title: Text(
                context.l10n.settingsBackgroundSharing,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                isWindowsDesktop
                    ? context.l10n.settingsBackgroundSharingWindows
                    : isMacDesktop
                    ? context.l10n.settingsBackgroundSharingMac
                    : context.l10n.settingsBackgroundSharingMobile,
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              value: model.backgroundSharingEnabled,
              onChanged:
                  (model.loading || model.backgroundSharingSaving) &&
                      !(model.backgroundSharingEnabled &&
                          model.backgroundSharingStarting)
                  ? null
                  : (enabled) =>
                        _run(() => model.setBackgroundSharing(enabled)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.backgroundSharingStarting
                        ? context.l10n.backgroundSharingStarting
                        : model.backgroundSharingSaving
                        ? context.l10n.backgroundSharingUpdating
                        : model.backgroundSharingError != null
                        ? context.l10n.backgroundSharingStartFailed
                        : !model.backgroundSharingEnabled
                        ? context.l10n.backgroundSharingOff
                        : model.backgroundSharingRunning
                        ? isWindowsDesktop
                              ? context.l10n.backgroundSharingRunningWindows
                              : isMacDesktop
                              ? context.l10n.backgroundSharingRunningMac
                              : context.l10n.backgroundSharingRunningMobile
                        : context.l10n.backgroundSharingNotRunning,
                    key: const Key('background-sharing-status'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                  if (model.backgroundSharingError != null &&
                      !model.backgroundSharingStarting &&
                      !model.backgroundSharingSaving) ...[
                    const SizedBox(height: 8),
                    Text(
                      model.backgroundSharingError!,
                      key: const Key('background-sharing-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ],
                  if (model.backgroundSharingEnabled &&
                      !model.backgroundSharingRunning &&
                      !model.backgroundSharingStarting &&
                      !model.backgroundSharingSaving) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      key: const Key('background-sharing-retry'),
                      onPressed: model.loading
                          ? null
                          : () => _run(() => model.setBackgroundSharing(true)),
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(context.l10n.backgroundSharingRetry),
                    ),
                  ],
                  if (!isDesktop &&
                      model.backgroundSharingEnabled &&
                      !model.batteryOptimizationExempt) ...[
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.backgroundSharingBatteryHint,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      key: const Key('background-sharing-battery-settings'),
                      onPressed: model.loading || model.backgroundSharingSaving
                          ? null
                          : () => _run(model.openBatteryOptimizationSettings),
                      icon: const Icon(Icons.battery_saver_outlined),
                      label: Text(
                        context.l10n.backgroundSharingBatterySettings,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _FolderTile(
        title: context.l10n.settingsDownloadFolder,
        subtitle:
            model.downloadFolder ?? context.l10n.settingsDownloadFolderEmpty,
        icon: Icons.save_alt_rounded,
        onTap: model.loading || model.busy
            ? null
            : () => _run(model.chooseDownloadFolder),
      ),
      const SizedBox(height: 12),
      Text(
        context.l10n.settingsSharingSummary(
          model.sharedFolders.length,
          model.localMediaCount,
        ),
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        context.l10n.settingsDownloadLayout,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
          height: 1.6,
        ),
      ),
      const SizedBox(height: 28),
      _SectionLabel(context.l10n.settingsDeviceInfo),
      _SurfaceCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                model.deviceName,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                model.addresses.isEmpty
                    ? context.l10n.settingsNoLan
                    : model.addresses
                          .map((address) => '$address:${model.port}')
                          .join('\n'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 28),
      _SectionLabel(context.l10n.settingsTips),
      _Tip(
        icon: Icons.wifi_rounded,
        title: context.l10n.tipNetworkTitle,
        description: context.l10n.tipNetworkDescription,
      ),
      if (isWindowsDesktop) ...[
        _Tip(
          icon: Icons.desktop_windows_rounded,
          title: context.l10n.tipWindowsTitle,
          description: context.l10n.tipWindowsDescription,
        ),
        _Tip(
          icon: Icons.downloading_rounded,
          title: context.l10n.tipBackgroundReceiveTitle,
          description: context.l10n.tipBackgroundReceiveWindows,
        ),
        _Tip(
          icon: Icons.keyboard_rounded,
          title: context.l10n.tipKeyboardTitle,
          description: context.l10n.tipKeyboardWindows,
        ),
      ] else if (isMacDesktop) ...[
        _Tip(
          icon: Icons.desktop_mac_rounded,
          title: context.l10n.tipMacTitle,
          description: context.l10n.tipMacDescription,
        ),
        _Tip(
          icon: Icons.downloading_rounded,
          title: context.l10n.tipBackgroundReceiveTitle,
          description: context.l10n.tipBackgroundReceiveMac,
        ),
        _Tip(
          icon: Icons.keyboard_rounded,
          title: context.l10n.tipKeyboardTitle,
          description: context.l10n.tipKeyboardMac,
        ),
      ] else
        _Tip(
          icon: Icons.phone_android_rounded,
          title: context.l10n.tipAndroidTitle,
          description: context.l10n.tipAndroidDescription,
        ),
      _Tip(
        icon: Icons.touch_app_outlined,
        title: isWindowsDesktop
            ? context.l10n.tipOpenTitle
            : context.l10n.tipShareTitle,
        description: isWindowsDesktop
            ? context.l10n.tipOpenDescription
            : context.l10n.tipShareDescription,
      ),
      const SizedBox(height: 28),
      _SectionLabel(context.l10n.settingsAboutProject),
      _SurfaceCard(
        child: ListTile(
          key: const Key('check-update-entry'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 8,
          ),
          leading: Icon(
            Icons.system_update_alt_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(context.l10n.settingsCheckUpdates),
          subtitle: Text(context.l10n.settingsCheckUpdatesSubtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => UpdatePage(shutdown: model.shutdownForUpdate),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _SurfaceCard(
        child: ListTile(
          key: const Key('about-entry'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 8,
          ),
          leading: Icon(
            Icons.info_outline_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(context.l10n.settingsAbout),
          subtitle: Text(context.l10n.settingsAboutSubtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(
            context,
          ).push<void>(MaterialPageRoute(builder: (_) => const AboutPage())),
        ),
      ),
      const SizedBox(height: 22),
      Center(
        child: Text(
          isWindowsDesktop
              ? 'TAMAYURA  /  Windows 10 / 11'
              : isMacDesktop
              ? 'TAMAYURA  /  macOS 15+'
              : 'TAMAYURA  /  Android 16+',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.4,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );
}

class _SyncProgressCard extends StatelessWidget {
  const _SyncProgressCard({
    required this.progress,
    required this.onRetry,
    required this.onDismiss,
  });

  final SyncProgress progress;
  final VoidCallback? onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = progress.phase == SyncPhase.failed;
    final completed = progress.phase == SyncPhase.completed;
    final total = progress.totalCount;
    final l10n = context.l10n;
    final status = switch (progress.phase) {
      SyncPhase.connecting => l10n.syncPhaseConnecting,
      SyncPhase.receiving => l10n.syncPhaseReceiving,
      SyncPhase.committing => l10n.syncPhaseCommitting,
      SyncPhase.completed => l10n.syncPhaseCompleted,
      SyncPhase.failed => l10n.syncPhaseFailed,
    };
    final detail = switch (progress.phase) {
      SyncPhase.connecting =>
        progress.readyCount > 0
            ? l10n.syncConnectingResume(progress.readyCount)
            : l10n.syncConnectingFresh,
      SyncPhase.receiving =>
        total == null
            ? l10n.syncReceivingOpen(progress.readyCount)
            : l10n.syncReceivingProgress(progress.readyCount, total),
      SyncPhase.committing => l10n.syncCommittingDetail,
      SyncPhase.completed => l10n.syncCompletedDetail(progress.readyCount),
      SyncPhase.failed =>
        progress.readyCount > 0
            ? l10n.syncFailedResume(progress.readyCount)
            : l10n.syncFailedFresh,
    };
    final value =
        progress.phase == SyncPhase.receiving && total != null && total > 0
        ? (progress.readyCount / total).clamp(0.0, 1.0)
        : null;
    return Semantics(
      container: true,
      liveRegion: progress.phase != SyncPhase.receiving,
      child: Container(
        key: Key('sync-progress-${progress.peerId}'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: failed ? colors.errorContainer : colors.surfaceContainer,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  failed
                      ? Icons.info_outline_rounded
                      : completed
                      ? Icons.check_circle_outline_rounded
                      : Icons.sync_rounded,
                  size: 20,
                  color: failed ? colors.onErrorContainer : colors.primary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    progress.peerName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  key: Key('dismiss-sync-${progress.peerId}'),
                  tooltip: l10n.syncDismiss,
                  onPressed: onDismiss,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: failed
                      ? colors.onErrorContainer
                      : colors.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(status, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              detail,
              style: TextStyle(
                color: failed
                    ? colors.onErrorContainer
                    : colors.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (!completed && !failed) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                key: Key('sync-indicator-${progress.peerId}'),
                value: value,
                semanticsLabel: l10n.syncProgressSemantics(
                  progress.peerName,
                  status,
                  detail,
                ),
                minHeight: 5,
                borderRadius: BorderRadius.circular(3),
              ),
            ],
            if (failed) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: Key('retry-sync-${progress.peerId}'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(l10n.syncContinue),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.collection,
    required this.deviceName,
    required this.onTap,
  });

  final MediaCollection collection;
  final String deviceName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _SurfaceCard(
    child: Semantics(
      label: context.l10n.collectionSemantics(
        collection.sharedFolderName,
        deviceName,
        collection.itemCount,
      ),
      button: true,
      child: InkWell(
        key: Key('collection-${collection.key}'),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox.expand(
                child: collection.thumbnail.isNotEmpty
                    ? Image.memory(
                        collection.thumbnail,
                        fit: BoxFit.cover,
                        cacheWidth: 640,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const _MissingThumbnail(),
                      )
                    : const _MissingThumbnail(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    collection.sharedFolderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    deviceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.albumMomentCount(collection.itemCount),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MediaCard extends StatelessWidget {
  const _MediaCard({
    required this.model,
    required this.detailed,
    required this.item,
    required this.deviceName,
    required this.online,
    required this.transfer,
    required this.onDownload,
    required this.onPreview,
    required this.onShare,
    required this.selecting,
    required this.selected,
    required this.selectionEnabled,
    required this.onSelect,
    this.onLongPress,
  });
  final TamayuraModel model;
  final bool detailed;
  final MediaView item;
  final String deviceName;
  final bool online;
  final TransferView? transfer;
  final VoidCallback onDownload, onShare, onPreview;
  final bool selecting, selected, selectionEnabled;
  final VoidCallback onSelect;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final running = transfer?.running ?? false;
    final complete = transfer?.complete ?? false;
    final image = Semantics(
      label: l10n.mediaSemantics(
        item.name,
        deviceName,
        complete
            ? l10n.mediaStateSaved
            : running
            ? l10n.mediaStateDownloading
            : transfer?.error != null
            ? l10n.mediaStateFailed
            : online
            ? l10n.mediaStateTapToDownload
            : l10n.mediaStateOffline,
      ),
      button: true,
      selected: selecting ? selected : null,
      enabled: !selecting || (complete && selectionEnabled),
      child: InkWell(
        key: Key('media-${item.key}'),
        onTap: selecting
            ? complete && selectionEnabled
                  ? onSelect
                  : null
            : onPreview,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: 'media-${item.key}',
              transitionOnUserGestures: true,
              child: AlbumImage(
                model: model,
                item: item,
                placeholder: const _MissingThumbnail(),
              ),
            ),
            if (item.isVideo)
              Positioned(
                top: detailed ? 8 : 4,
                left: detailed ? 8 : 4,
                child: detailed
                    ? _ImageBadge(
                        icon: Icons.videocam_rounded,
                        label: l10n.commonVideo,
                      )
                    : _CompactImageBadge(
                        icon: Icons.videocam_rounded,
                        label: l10n.commonVideo,
                      ),
              ),
            if (detailed)
              Positioned(
                bottom: 8,
                left: 8,
                child: _ImageBadge(
                  icon: complete
                      ? Icons.check_circle_rounded
                      : online
                      ? Icons.download_rounded
                      : Icons.cloud_off_rounded,
                  label: complete
                      ? l10n.mediaStateSaved
                      : online
                      ? _formatBytes(item.size)
                      : l10n.mediaDeviceOffline,
                ),
              ),
            if (!detailed &&
                !running &&
                (complete || transfer?.error != null || !online))
              Positioned(
                bottom: 4,
                right: 4,
                child: _CompactImageBadge(
                  icon: complete
                      ? Icons.check_circle_rounded
                      : transfer?.error != null
                      ? Icons.error_outline_rounded
                      : Icons.cloud_off_rounded,
                  label: complete
                      ? l10n.mediaStateSaved
                      : transfer?.error != null
                      ? l10n.mediaStateFailed
                      : l10n.mediaDeviceOffline,
                ),
              ),
            if (running)
              ColoredBox(
                color: Colors.black45,
                child: Center(
                  child: !detailed
                      ? SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(
                            value: transfer!.progress.clamp(0, 1).toDouble(),
                            strokeWidth: 2,
                            color: Colors.white,
                            backgroundColor: Colors.white30,
                            semanticsLabel: l10n.mediaDownloadingName(
                              item.name,
                            ),
                            semanticsValue:
                                '${(transfer!.progress * 100).round()}%',
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(
                              value: transfer!.progress.clamp(0, 1).toDouble(),
                              color: Colors.white,
                              backgroundColor: Colors.white30,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '${(transfer!.progress * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            if (selecting)
              Positioned(
                top: 4,
                right: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    shape: BoxShape.circle,
                  ),
                  child: Checkbox(
                    key: Key('select-local-${item.key}'),
                    value: selected,
                    onChanged: complete && selectionEnabled
                        ? (_) => onSelect()
                        : null,
                    semanticLabel: complete
                        ? l10n.mediaSelectName(item.name)
                        : l10n.mediaNotSavedName(item.name),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (!detailed) {
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        clipBehavior: Clip.hardEdge,
        child: image,
      );
    }
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: image),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
            child: Text(
              deviceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            height: 40 * MediaQuery.textScalerOf(context).scale(1),
            child: selecting
                ? Center(
                    child: Text(
                      complete ? l10n.mediaDeleteLocalOnly : l10n.mediaNotSaved,
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                : complete
                ? TextButton.icon(
                    key: Key('share-${item.key}'),
                    onPressed: onShare,
                    icon: const Icon(Icons.ios_share_rounded, size: 14),
                    label: Text(
                      l10n.commonShare,
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                : transfer?.error != null
                ? TextButton.icon(
                    key: Key('retry-${item.key}'),
                    onPressed: onDownload,
                    icon: const Icon(Icons.refresh_rounded, size: 14),
                    label: Text(
                      l10n.mediaDownloadFailedRetry,
                      style: const TextStyle(fontSize: 11),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        running
                            ? l10n.mediaReceivingOriginal
                            : l10n.mediaCardDate(item.modified.toLocal()),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

String _formatSuccessfulSync(AppLocalizations l10n, DateTime? timestamp) {
  if (timestamp == null) return l10n.deviceNeverSynced;
  final local = timestamp.toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-'
      '${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}:'
      '${twoDigits(local.second)}';
}

String _formatBytes(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).ceil()} KB';

class _MissingThumbnail extends StatelessWidget {
  const _MissingThumbnail();
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(
      child: Icon(
        Icons.image_outlined,
        size: 32,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _CompactImageBadge extends StatelessWidget {
  const _CompactImageBadge({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(icon, size: 14, color: Colors.white),
      ),
    ),
  );
}

class _ImageBadge extends StatelessWidget {
  const _ImageBadge({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Colors.white),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.white)),
      ],
    ),
  );
}

class _PageHeading extends StatelessWidget {
  const _PageHeading({required this.title, required this.subtitle});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 9),
      Text(
        subtitle,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
    ],
  );
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child, this.margin});
  final Widget child;
  final EdgeInsets? margin;
  @override
  Widget build(BuildContext context) => Container(
    margin: margin,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Material(color: Colors.transparent, child: child),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });
  final IconData icon;
  final String title, description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 30,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      const SizedBox(height: 20),
      Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 10),
      Text(
        description,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.7,
          fontSize: 13,
        ),
      ),
      if (action != null) ...[const SizedBox(height: 14), action!],
    ],
  );
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });
  final String title, subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => _SurfaceCard(
    child: ListTile(
      contentPadding: const EdgeInsets.all(14),
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          subtitle,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, height: 1.6),
        ),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
    ),
  );
}

class _Tip extends StatelessWidget {
  const _Tip({
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title, description;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 5),
              Text(
                description,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({
    required this.message,
    required this.onDismiss,
    required this.onRetry,
  });
  final String message;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      key: const Key('error-banner'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 5),
            child: Icon(
              Icons.info_outline_rounded,
              size: 19,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                TextButton(
                  onPressed: onRetry,
                  child: Text(context.l10n.homeErrorRetry),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.l10n.homeErrorDismiss,
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    ),
  );
}

class _AutoSyncIntervalDialog extends StatefulWidget {
  const _AutoSyncIntervalDialog({
    required this.initialMinutes,
    required this.onSave,
  });

  final int initialMinutes;
  final Future<bool> Function(int minutes) onSave;

  @override
  State<_AutoSyncIntervalDialog> createState() =>
      _AutoSyncIntervalDialogState();
}

class _AutoSyncIntervalDialogState extends State<_AutoSyncIntervalDialog> {
  late final _controller = TextEditingController(
    text: '${widget.initialMinutes}',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final text = _controller.text.trim();
    final minutes = RegExp(r'^[0-9]+$').hasMatch(text)
        ? int.tryParse(text)
        : null;
    if (minutes == null || minutes < 1 || minutes > 525600) {
      setState(() => _error = context.l10n.autoSyncDialogInvalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.onSave(minutes);
      if (!mounted) return;
      if (saved) {
        Navigator.of(context).pop();
      } else {
        setState(() => _error = context.l10n.autoSyncDialogSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(context.l10n.settingsAutoSyncInterval),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.autoSyncDialogDescription,
              style: const TextStyle(height: 1.5),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('auto-sync-interval-input'),
              controller: _controller,
              enabled: !_saving,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: context.l10n.autoSyncDialogLabel,
                helperText: context.l10n.autoSyncDialogHelper,
                errorText: _error,
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('auto-sync-interval-cancel'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('auto-sync-interval-save'),
          onPressed: _saving ? null : _save,
          child: Text(
            _saving ? context.l10n.commonSaving : context.l10n.commonSave,
          ),
        ),
      ],
    ),
  );
}

enum _DeviceAction { enableSync, forget }

class _SyncApprovalDialog extends StatelessWidget {
  const _SyncApprovalDialog({required this.device});
  final DeviceView device;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('sync-approval-dialog'),
    title: Text(context.l10n.syncApprovalTitle),
    content: Text(
      context.l10n.syncApprovalMessage(device.name, device.address),
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        height: 1.5,
      ),
    ),
    actions: [
      TextButton(
        key: const Key('sync-approval-decline'),
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(context.l10n.syncApprovalDecline),
      ),
      FilledButton(
        key: const Key('sync-approval-accept'),
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(context.l10n.syncApprovalAccept),
      ),
    ],
  );
}

class _ForgetDeviceDialog extends StatelessWidget {
  const _ForgetDeviceDialog({required this.device});
  final DeviceView device;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('forget-device-dialog'),
    title: Text(context.l10n.deviceForgetTitle(device.name)),
    content: Text(
      context.l10n.deviceForgetMessage,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        height: 1.5,
      ),
    ),
    actions: [
      TextButton(
        key: const Key('forget-device-cancel'),
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(context.l10n.commonCancel),
      ),
      FilledButton(
        key: const Key('forget-device-confirm'),
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
          foregroundColor: Theme.of(context).colorScheme.onError,
        ),
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(context.l10n.deviceForget),
      ),
    ],
  );
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();
  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _controller = TextEditingController();
  bool _empty = false;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _empty = true);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.connectDialogTitle),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.connectDialogHint,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('ip-input'),
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: context.l10n.connectDialogLabel,
            hintText: '192.168.1.20:${LanEndpoint.defaultPort}',
            errorText: _empty ? context.l10n.connectDialogEmpty : null,
          ),
          onSubmitted: (_) => _submit(),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.l10n.commonCancel),
      ),
      FilledButton(
        key: const Key('confirm-connect'),
        onPressed: _submit,
        child: Text(context.l10n.commonConnect),
      ),
    ],
  );
}

class _DeviceQrDialog extends StatefulWidget {
  const _DeviceQrDialog({
    required this.name,
    required this.addresses,
    required this.port,
  });
  final String name;
  final List<String> addresses;
  final int port;
  @override
  State<_DeviceQrDialog> createState() => _DeviceQrDialogState();
}

class _DeviceQrDialogState extends State<_DeviceQrDialog> {
  late String _address = widget.addresses.first;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.name),
    content: SizedBox(
      width: 250,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.qrDialogHint,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              label: context.l10n.qrSemantics(_address, widget.port),
              child: QrImageView(
                data: Uri(
                  scheme: 'tamayura',
                  host: _address,
                  port: widget.port,
                  queryParameters: {'v': '1'},
                ).toString(),
                backgroundColor: Colors.white,
                size: 230,
              ),
            ),
            const SizedBox(height: 12),
            if (widget.addresses.length > 1)
              DropdownButton<String>(
                value: _address,
                isExpanded: true,
                items: widget.addresses
                    .map(
                      (address) => DropdownMenuItem(
                        value: address,
                        child: Text(address),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _address = value);
                },
              )
            else
              Text(
                '$_address:${widget.port}',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.l10n.commonDone),
      ),
    ],
  );
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();
  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool _handled = false;
  bool _invalidCode = false;
  @override
  Widget build(BuildContext context) => Theme(
    data: AppTheme.dark,
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.dark.appBarTheme.systemOverlayStyle!,
      child: Scaffold(
        appBar: AppBar(title: Text(context.l10n.scannerTitle)),
        body: Column(
          children: [
            Expanded(
              child: MobileScanner(
                onDetect: (capture) {
                  if (_handled) return;
                  for (final barcode in capture.barcodes) {
                    final value = barcode.rawValue;
                    if (value == null) continue;
                    final uri = Uri.tryParse(value);
                    if (uri?.scheme != 'tamayura' || uri!.host.isEmpty) {
                      if (!_invalidCode) setState(() => _invalidCode = true);
                      continue;
                    }
                    _handled = true;
                    Navigator.of(context).pop(value);
                    return;
                  }
                },
                errorBuilder: (context, error) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.no_photography_outlined,
                          color: Colors.white,
                          size: 40,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.scannerCameraUnavailable,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(context.l10n.scannerBack),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: SafeArea(
                top: false,
                child: Text(
                  _invalidCode
                      ? context.l10n.scannerInvalidCode
                      : context.l10n.scannerHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, height: 1.6),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
