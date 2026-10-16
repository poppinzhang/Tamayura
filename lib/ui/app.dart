import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/view_state.dart';
import '../app/endpoint.dart';
import 'about_page.dart';
import 'app_theme.dart';
import 'downloads_page.dart';
import 'desktop_layout.dart';
import 'media_preview.dart';

class TamayuraApp extends StatelessWidget {
  const TamayuraApp({super.key, required this.model});

  final TamayuraModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      title: 'Tamayura · 玉响',
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

class _HomeState extends State<_Home> {
  int _tab = 0;
  bool _connecting = false;
  final _albumScroll = ScrollController();
  bool _requestingMore = false;
  String? _loadMoreError;
  TamayuraModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _albumScroll.addListener(_onAlbumScroll);
  }

  @override
  void dispose() {
    _albumScroll.dispose();
    super.dispose();
  }

  void _onAlbumScroll() {
    if (_tab == 0 &&
        model.selectedCollectionKey != null &&
        _albumScroll.position.extentAfter < 450 &&
        model.hasMoreMedia &&
        !model.loadingMoreMedia &&
        !_requestingMore &&
        _loadMoreError == null &&
        model.error == null) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    if (_requestingMore || model.loadingMoreMedia || !model.hasMoreMedia) {
      return;
    }
    setState(() {
      _requestingMore = true;
      _loadMoreError = null;
    });
    try {
      await model.loadMoreMedia();
    } catch (_) {
      if (mounted) setState(() => _loadMoreError = '更多照片暂时未能加载，请重试。');
    } finally {
      if (mounted) setState(() => _requestingMore = false);
    }
  }

  Future<void> _selectDevice(String? id) async {
    _loadMoreError = null;
    await _run(() => model.selectDevice(id));
    if (mounted && _albumScroll.hasClients) _albumScroll.jumpTo(0);
  }

  Future<void> _selectCollection(String? key) async {
    _loadMoreError = null;
    await _run(() => model.selectCollection(key));
    if (mounted && _albumScroll.hasClients) _albumScroll.jumpTo(0);
  }

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

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('操作未能完成，请检查网络与目录权限后重试。')));
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

  void _changeTab(int tab) => setState(() => _tab = tab);

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
    destinations: const [
      NavigationRailDestination(
        icon: Icon(Icons.photo_library_outlined, key: Key('album-tab')),
        selectedIcon: Icon(Icons.photo_library_rounded, key: Key('album-tab')),
        label: Text('相册'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.devices_outlined, key: Key('devices-tab')),
        selectedIcon: Icon(Icons.devices_rounded, key: Key('devices-tab')),
        label: Text('设备'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.tune_rounded, key: Key('settings-tab')),
        label: Text('设置'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
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
              canPop: _tab != 0 || model.selectedCollectionKey == null,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) unawaited(_selectCollection(null));
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
                      SizedBox(width: 8),
                      Text(
                        '玉响',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    IconButton(
                      key: const Key('downloads-entry'),
                      tooltip: '下载任务',
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
                      tooltip: '刷新设备和相册',
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
                            Expanded(
                              child:
                                  model.loading &&
                                      !(_tab == 2 &&
                                          model.backgroundSharingEnabled &&
                                          model.backgroundSharingStarting)
                                  ? const Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          CircularProgressIndicator(),
                                          SizedBox(height: 20),
                                          Text('正在打开你的随身相册…'),
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
                        onDestinationSelected: (value) =>
                            setState(() => _tab = value),
                        destinations: const [
                          NavigationDestination(
                            key: Key('album-tab'),
                            icon: Icon(Icons.photo_library_outlined),
                            selectedIcon: Icon(Icons.photo_library_rounded),
                            label: '相册',
                          ),
                          NavigationDestination(
                            key: Key('devices-tab'),
                            icon: Icon(Icons.devices_outlined),
                            selectedIcon: Icon(Icons.devices_rounded),
                            label: '设备',
                          ),
                          NavigationDestination(
                            key: Key('settings-tab'),
                            icon: Icon(Icons.tune_rounded),
                            label: '设置',
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
    return RefreshIndicator(
      onRefresh: () => _run(model.refresh),
      child: CustomScrollView(
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
                  const Text(
                    '每一刻，都在手边。',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '按共享文件夹浏览合集，轻点照片就存到这里。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 22),
                  if (model.sharedFolders.isEmpty ||
                      model.downloadFolder == null)
                    _setupCard(),
                  if (devices.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _filterChip(null, '全部设备', null),
                          for (final device in devices)
                            _filterChip(device.id, device.name, device.online),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  for (final progress in syncProgress)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _SyncProgressCard(
                        progress: progress,
                        onRetry: model.busy
                            ? null
                            : () =>
                                  _run(() => model.retrySync(progress.peerId)),
                      ),
                    ),
                  if (browsingCollection) ...[
                    TextButton.icon(
                      key: const Key('back-to-collections'),
                      onPressed: () => _selectCollection(null),
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: const Text('全部合集'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      collection?.sharedFolderName ?? '共享合集',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (!browsingCollection && collections.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(
                        '${collections.length} 个合集',
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
                              '${model.totalMediaCount} 个瞬间',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Flexible(
                            child: Text(
                              '轻点下载原文件',
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
          if (browsingCollection ? media.isEmpty : collections.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 36, 28, 40),
                child: _EmptyState(
                  icon: Icons.photo_library_outlined,
                  title: syncing
                      ? '正在接收相册'
                      : syncFailed
                      ? '同步尚未完成'
                      : devices.isEmpty
                      ? '让照片相遇'
                      : browsingCollection
                      ? '这个合集还没有照片'
                      : '这里还没有合集',
                  description: syncing
                      ? '缩略图会陆续显示，你可以边同步边浏览。'
                      : syncFailed
                      ? '请检查两台设备的连接，然后重试同步。'
                      : devices.isEmpty
                      ? '在另一台设备上打开玉响，连接同一个局域网。\n发现设备后，共享文件夹会以合集出现在这里。'
                      : isDesktop
                      ? '对方需要选择共享目录，并保持玉响运行。\n点击右上角刷新，更新已连接设备的相册。'
                      : '对方需要选择共享目录，开启后台共享后锁屏也能访问。\n你也可以下拉刷新，更新已连接设备的相册。',
                  action: syncing || syncFailed
                      ? null
                      : TextButton.icon(
                          onPressed: () => setState(() => _tab = 1),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('连接一台设备'),
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
                        deviceName: device?.name ?? '已记住的设备',
                        onTap: () => _selectCollection(item.key),
                      );
                    }, childCount: collections.length),
                  );
                },
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final count = (constraints.crossAxisExtent / 175)
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
                          constraints.crossAxisExtent / count + 90 * textScale,
                    ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final item = media[index];
                      final device = devices
                          .where((device) => device.id == item.deviceId)
                          .firstOrNull;
                      return _MediaCard(
                        item: item,
                        deviceName: device?.name ?? '已记住的设备',
                        online: device?.online ?? false,
                        transfer: model.transfers[item.key],
                        onPreview: () => _preview(item),
                        onDownload: () => _run(() => model.download(item)),
                        onShare: () => _run(() => model.share(item)),
                      );
                    }, childCount: media.length),
                  );
                },
              ),
            ),
          if (browsingCollection &&
              (model.hasMoreMedia ||
                  model.loadingMoreMedia ||
                  _requestingMore ||
                  _loadMoreError != null))
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 26),
                child: Column(
                  children: [
                    if (_loadMoreError != null)
                      Text(
                        _loadMoreError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (model.loadingMoreMedia || _requestingMore)
                      const Padding(
                        padding: EdgeInsets.all(14),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Text('正在加载更多照片…'),
                          ],
                        ),
                      )
                    else
                      TextButton.icon(
                        key: const Key('load-more-media'),
                        onPressed: _loadMore,
                        icon: const Icon(Icons.expand_more_rounded),
                        label: Text(_loadMoreError == null ? '加载更多照片' : '重试加载'),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

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
        const Row(
          children: [
            Icon(Icons.folder_open_rounded, size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '先安顿好你的相册',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text('添加要分享的文件夹，以及收到照片后存放的位置。', style: TextStyle(height: 1.5)),
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
                label: const Text('共享文件夹'),
              ),
            if (model.downloadFolder == null)
              FilledButton.icon(
                key: const Key('setup-download'),
                onPressed: model.busy
                    ? null
                    : () => _run(model.chooseDownloadFolder),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('接收目录'),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _devices() => RefreshIndicator(
    onRefresh: () => _run(model.refresh),
    child: ListView(
      key: const PageStorageKey('devices-scroll'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 30),
      children: [
        const _PageHeading(title: '附近的伙伴', subtitle: '同一个局域网，让每台设备的相册连在一起。'),
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
                  Text(
                    '这台设备',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                    ? '暂无局域网地址，请连接网络后刷新'
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
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                icon: const Icon(Icons.qr_code_rounded, size: 18),
                label: const Text('展示连接二维码'),
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
              label: const Text('输入 IP 连接'),
            ),
            if (!isWindowsDesktop)
              OutlinedButton.icon(
                onPressed: _connecting || model.busy ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                label: const Text('扫一扫'),
              ),
          ],
        ),
        if (_connecting) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Text(
            '正在连接设备…',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 30),
        Row(
          children: [
            const Expanded(
              child: Text(
                '已记住的设备',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${model.devices.where((device) => device.online).length} 台在线',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (model.devices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: _EmptyState(
              icon: Icons.radar_rounded,
              title: '等待另一台玉响',
              description: '设备会通过局域网自动发现。\n如果暂时没找到，可以输入 IP 或扫描二维码连接。',
            ),
          ),
        for (final device in model.devices)
          _SurfaceCard(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 8,
              ),
              leading: CircleAvatar(
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.devices_rounded,
                  color: device.online
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              title: Text(
                device.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${device.online ? '在线' : '离线 · 可浏览缓存'}\n${device.address}',
                style: const TextStyle(height: 1.6, fontSize: 12),
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                _selectDevice(device.id);
                setState(() => _tab = 0);
              },
            ),
          ),
        const SizedBox(height: 12),
        Text(
          isWindowsDesktop
              ? '设备离线后仍会保留相册缩略图。共享与接收需要玉响运行、电脑保持唤醒，并与来源设备处于同一局域网。'
              : isMacDesktop
              ? '设备离线后仍会保留相册缩略图。共享与接收需要玉响保持运行、Mac 保持唤醒，并与来源设备处于同一局域网。'
              : '设备离线后仍会保留相册缩略图。来源设备开启后台共享后，锁屏也能提供原文件；这台设备可以切换到其他应用继续接收。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.6,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );

  Widget _settings() => ListView(
    key: const PageStorageKey('settings-scroll'),
    padding: const EdgeInsets.fromLTRB(22, 20, 22, 30),
    children: [
      const _PageHeading(title: '你的相册，你来安排', subtitle: '只分享选定的目录，原文件按需获取。'),
      const SizedBox(height: 26),
      const _SectionLabel('外观'),
      _SurfaceCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '主题模式',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('跟随系统', maxLines: 1),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('浅色', maxLines: 1),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('深色', maxLines: 1),
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
                    ? '正在保存主题…'
                    : model.themeMode == ThemeMode.system
                    ? '随系统自动切换浅色和深色外观。'
                    : '已固定为${model.themeMode == ThemeMode.light ? '浅色' : '深色'}外观。',
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
      const SizedBox(height: 28),
      const _SectionLabel('文件与存储'),
      _SurfaceCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '共享文件夹',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '可添加多个文件夹，自动包含所有子目录。已添加的目录及其父目录、子目录不能重复添加。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
              if (model.sharedFolders.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text('尚未选择 · 让其他设备看到这里的照片'),
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
                    tooltip: '移除 ${folder.name}',
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
                label: const Text('添加共享文件夹'),
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
              title: const Text(
                '后台共享',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                isWindowsDesktop
                    ? '开启后，最小化窗口仍可共享；关闭后在窗口隐藏时停止共享。玉响需要保持运行，电脑需要保持唤醒。'
                    : isMacDesktop
                    ? '开启后，隐藏或最小化窗口仍可共享；关闭后在窗口隐藏时停止共享。玉响需要保持运行，Mac 需要保持唤醒。'
                    : '开启后锁屏仍可共享媒体；关闭后仅在使用应用时共享，更省电。',
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
                        ? '正在启动后台共享…'
                        : model.backgroundSharingSaving
                        ? '正在更新后台共享…'
                        : model.backgroundSharingError != null
                        ? '后台共享启动失败，请重试。'
                        : !model.backgroundSharingEnabled
                        ? '后台共享已关闭。'
                        : model.backgroundSharingRunning
                        ? isWindowsDesktop
                              ? '后台共享正在运行。电脑睡眠或退出玉响后，共享会停止。'
                              : isMacDesktop
                              ? '后台共享正在运行。Mac 睡眠或退出玉响后，共享会停止。'
                              : '后台共享正在运行，锁屏后仍可访问已选目录。'
                        : '后台共享尚未运行。',
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
                      label: const Text('重试后台共享'),
                    ),
                  ],
                  if (!isDesktop &&
                      model.backgroundSharingEnabled &&
                      !model.batteryOptimizationExempt) ...[
                    const SizedBox(height: 8),
                    Text(
                      '系统省电限制可能在休眠时中断共享。可在电池设置中允许玉响不受限制地运行。',
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
                      label: const Text('电池设置'),
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
        title: '接收目录',
        subtitle: model.downloadFolder ?? '尚未选择 · 下载的原文件会保存在这里',
        icon: Icons.save_alt_rounded,
        onTap: model.loading || model.busy
            ? null
            : () => _run(model.chooseDownloadFolder),
      ),
      const SizedBox(height: 12),
      Text(
        '当前从 ${model.sharedFolders.length} 个目录共享 ${model.localMediaCount} 个媒体文件',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        '原文件按「对端设备 / 共享文件夹 / 原有子目录」保存，保留目录层级。',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
          height: 1.6,
        ),
      ),
      const SizedBox(height: 28),
      const _SectionLabel('本机信息'),
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
                    ? '尚未连接局域网'
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
      const _SectionLabel('使用小提示'),
      const _Tip(
        icon: Icons.wifi_rounded,
        title: '连接同一个网络',
        description: '目前仅支持局域网，设备无需登录账号。请只在可信的网络中共享目录。',
      ),
      if (isWindowsDesktop) ...[
        const _Tip(
          icon: Icons.desktop_windows_rounded,
          title: '为 Windows 准备',
          description:
              '支持 Windows 10 1809 及更新版本、Windows 11（x64）。请允许玉响通过专用网络防火墙；也可使用手动 IP 连接。',
        ),
        const _Tip(
          icon: Icons.downloading_rounded,
          title: '最小化后，接收继续',
          description: '保持玉响运行和电脑唤醒即可继续下载。关闭窗口会退出应用；睡眠或断网后可在下载任务中重试。',
        ),
        const _Tip(
          icon: Icons.keyboard_rounded,
          title: '用键盘快速切换',
          description:
              'Ctrl+1 相册 · Ctrl+2 设备 · Ctrl+3 或 Ctrl+, 设置 · Ctrl+R 刷新。',
        ),
      ] else if (isMacDesktop) ...[
        const _Tip(
          icon: Icons.desktop_mac_rounded,
          title: '为 Mac 准备',
          description:
              '支持 macOS Sequoia 15、Tahoe 26 及后续版本。目录访问和相机权限由系统管理，可在系统设置中调整。',
        ),
        const _Tip(
          icon: Icons.downloading_rounded,
          title: '切换应用，接收继续',
          description: '保持玉响运行和 Mac 唤醒即可继续下载。退出应用或系统睡眠会中断传输，恢复后可在下载任务中重试。',
        ),
        const _Tip(
          icon: Icons.keyboard_rounded,
          title: '用键盘快速切换',
          description: '⌘1 相册 · ⌘2 设备 · ⌘3 或 ⌘, 设置 · ⌘R 刷新。',
        ),
      ] else
        const _Tip(
          icon: Icons.phone_android_rounded,
          title: '接收可在后台继续',
          description:
              '支持 Android 16 及更新版本。通知权限为可选项，关闭通知仍可下载并在下载中心查看进度；来源设备开启后台共享后可以锁屏，双方需要处于同一局域网。',
        ),
      _Tip(
        icon: Icons.touch_app_outlined,
        title: isWindowsDesktop ? '轻点获取，下载后打开' : '轻点获取，下载后分享',
        description: isWindowsDesktop
            ? '每个共享文件夹显示为独立合集；点击下载原文件，可用系统应用打开，或在资源管理器中定位文件。'
            : '每个共享文件夹显示为独立合集，包含其所有子目录的照片与视频；点击下载原文件，再使用分享按钮发送到其他应用。',
      ),
      const SizedBox(height: 28),
      const _SectionLabel('关于项目'),
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
          title: const Text('关于'),
          subtitle: const Text('版本、开源许可与一点碎碎念'),
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
  const _SyncProgressCard({required this.progress, required this.onRetry});

  final SyncProgress progress;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = progress.phase == SyncPhase.failed;
    final completed = progress.phase == SyncPhase.completed;
    final total = progress.totalCount;
    final status = switch (progress.phase) {
      SyncPhase.connecting => '正在连接',
      SyncPhase.receiving => '正在同步相册',
      SyncPhase.committing => '正在完成同步',
      SyncPhase.completed => '相册同步完成',
      SyncPhase.failed => '本次同步未完成',
    };
    final detail = switch (progress.phase) {
      SyncPhase.connecting =>
        progress.readyCount > 0
            ? '已保留 ${progress.readyCount} 项，正在连接设备继续同步。'
            : '正在获取相册信息，请保持设备连接。',
      SyncPhase.receiving =>
        total == null
            ? '已就绪 ${progress.readyCount} 项，正在获取更多照片。'
            : '已就绪 ${progress.readyCount} / $total 项，可边同步边浏览。',
      SyncPhase.committing => '缩略图已就绪，正在整理相册。',
      SyncPhase.completed => '已就绪 ${progress.readyCount} 项。',
      SyncPhase.failed =>
        progress.readyCount > 0
            ? '已保留 ${progress.readyCount} 项，恢复连接后可继续同步。'
            : '相册和同步进度已保留，请检查连接后重试。',
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
        padding: const EdgeInsets.all(16),
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
                semanticsLabel: '${progress.peerName}，$status，$detail',
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
                label: const Text('继续同步'),
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
      label:
          '${collection.sharedFolderName}，来自$deviceName，${collection.itemCount} 个瞬间',
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
                    '${collection.itemCount} 个瞬间',
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
    required this.item,
    required this.deviceName,
    required this.online,
    required this.transfer,
    required this.onDownload,
    required this.onPreview,
    required this.onShare,
  });
  final MediaView item;
  final String deviceName;
  final bool online;
  final TransferView? transfer;
  final VoidCallback onDownload, onShare, onPreview;

  @override
  Widget build(BuildContext context) {
    final running = transfer?.running ?? false;
    final complete = transfer?.complete ?? false;
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Semantics(
              label:
                  '${item.name}，来自$deviceName，${complete
                      ? '已保存'
                      : running
                      ? '正在下载'
                      : '点击下载原文件'}',
              button: true,
              child: InkWell(
                key: Key('media-${item.key}'),
                onTap: onPreview,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Hero(
                      tag: 'media-${item.key}',
                      transitionOnUserGestures: true,
                      child: item.thumbnail.isNotEmpty
                          ? Image.memory(
                              item.thumbnail,
                              fit: BoxFit.cover,
                              cacheWidth: 640,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) =>
                                  const _MissingThumbnail(),
                            )
                          : const _MissingThumbnail(),
                    ),
                    if (item.isVideo)
                      const Positioned(
                        top: 8,
                        left: 8,
                        child: _ImageBadge(
                          icon: Icons.videocam_rounded,
                          label: '视频',
                        ),
                      ),
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
                            ? '已保存'
                            : online
                            ? _formatBytes(item.size)
                            : '设备离线',
                      ),
                    ),
                    if (running)
                      ColoredBox(
                        color: Colors.black45,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(
                                value: transfer!.progress
                                    .clamp(0, 1)
                                    .toDouble(),
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
                  ],
                ),
              ),
            ),
          ),
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
            child: complete
                ? TextButton.icon(
                    key: Key('share-${item.key}'),
                    onPressed: onShare,
                    icon: const Icon(Icons.ios_share_rounded, size: 14),
                    label: const Text('分享', style: TextStyle(fontSize: 12)),
                  )
                : transfer?.error != null
                ? TextButton.icon(
                    key: Key('retry-${item.key}'),
                    onPressed: onDownload,
                    icon: const Icon(Icons.refresh_rounded, size: 14),
                    label: const Text(
                      '下载失败 · 重试',
                      style: TextStyle(fontSize: 11),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        running
                            ? '正在接收原文件…'
                            : '${item.modified.month} 月 ${item.modified.day} 日',
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
                TextButton(onPressed: onRetry, child: const Text('重试连接与刷新')),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭提示',
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    ),
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
    title: const Text('连接另一台设备'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '在对方的「设备」页面找到 IP 地址。',
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
            labelText: 'IP 地址与端口',
            hintText: '192.168.1.20:${LanEndpoint.defaultPort}',
            errorText: _empty ? '请输入对方的 IP 地址' : null,
          ),
          onSubmitted: (_) => _submit(),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('confirm-connect'),
        onPressed: _submit,
        child: const Text('连接'),
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
              '另一台设备打开玉响扫一扫',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              label: '本机连接二维码，地址 $_address，端口 ${widget.port}',
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
        child: const Text('完成'),
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
  String? _message;
  @override
  Widget build(BuildContext context) => Theme(
    data: AppTheme.dark,
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.dark.appBarTheme.systemOverlayStyle!,
      child: Scaffold(
        appBar: AppBar(title: const Text('扫描设备二维码')),
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
                      if (_message == null) {
                        setState(
                          () => _message = '这不是玉响的设备二维码，请扫描对方「设备」页面的二维码。',
                        );
                      }
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
                        const Text(
                          '无法打开相机。请在系统设置中允许相机权限，或返回后输入 IP 连接。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, height: 1.6),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('返回设备页面'),
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
                  _message ?? '将对方的设备二维码放入镜头中\n双方需要连接同一个局域网',
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
