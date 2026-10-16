import 'package:flutter/material.dart';

import '../app/app_info.dart';
import '../app/endpoint.dart';

const _projectName = 'Tamayura · 玉响';
const _projectSummary = '在局域网设备之间浏览与按需传递照片、视频，让美好的瞬间随手可及。';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.loadVersion = AppVersion.load});

  final Future<AppVersion> Function() loadVersion;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late Future<AppVersion> _version;

  @override
  void initState() {
    super.initState();
    _version = Future.sync(widget.loadVersion);
  }

  @override
  Widget build(BuildContext context) => _InfoPage(
    pageKey: const Key('about-page'),
    title: '关于',
    children: [
      const SizedBox(height: 12),
      Icon(
        Icons.blur_circular_rounded,
        size: 64,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(height: 16),
      const Text(
        _projectName,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 12),
      const Text(
        _projectSummary,
        textAlign: TextAlign.center,
        style: TextStyle(height: 1.7),
      ),
      const SizedBox(height: 28),
      _InfoCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('版本号', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              FutureBuilder<AppVersion>(
                future: _version,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Text('正在读取版本…');
                  }
                  if (snapshot.hasError || !snapshot.hasData) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('暂时无法读取版本信息'),
                        TextButton.icon(
                          key: const Key('retry-app-version'),
                          onPressed: () => setState(() {
                            _version = Future.sync(widget.loadVersion);
                          }),
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试'),
                        ),
                      ],
                    );
                  }
                  return SelectableText(
                    snapshot.data!.displayVersion,
                    key: const Key('app-version'),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      _InfoCard(
        child: ListTile(
          key: const Key('project-license-entry'),
          leading: const Icon(Icons.code_rounded),
          title: const Text('项目开源许可'),
          subtitle: const Text('Apache-2.0'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const ProjectLicensePage()),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _InfoCard(
        child: ListTile(
          key: const Key('dependency-licenses-entry'),
          leading: const Icon(Icons.description_outlined),
          title: const Text('第三方开源许可'),
          subtitle: const Text('感谢 Flutter 与开源社区'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () =>
              showLicensePage(context: context, applicationName: _projectName),
        ),
      ),
      const SizedBox(height: 12),
      _InfoCard(
        child: ListTile(
          key: const Key('musings-entry'),
          leading: const Icon(Icons.photo_camera_outlined),
          title: const Text('碎碎念'),
          subtitle: const Text('关于名字、摄影，还有一个特别的端口'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(
            context,
          ).push<void>(MaterialPageRoute(builder: (_) => const MusingsPage())),
        ),
      ),
    ],
  );
}

class ProjectLicensePage extends StatefulWidget {
  const ProjectLicensePage({super.key});

  @override
  State<ProjectLicensePage> createState() => _ProjectLicensePageState();
}

class _ProjectLicensePageState extends State<ProjectLicensePage> {
  Future<String>? _license;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _license ??= DefaultAssetBundle.of(
      context,
    ).loadString('LICENSE', cache: false);
  }

  @override
  Widget build(BuildContext context) => _InfoPage(
    pageKey: const Key('project-license-page'),
    title: 'Apache-2.0',
    children: [
      const Text(
        'Tamayura 采用 Apache License 2.0 开源许可。以下为完整许可正文。',
        style: TextStyle(height: 1.7),
      ),
      const SizedBox(height: 20),
      FutureBuilder<String>(
        future: _license,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Text('正在读取许可…');
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('暂时无法读取许可正文'),
                TextButton.icon(
                  key: const Key('retry-project-license'),
                  onPressed: () => setState(() {
                    _license = DefaultAssetBundle.of(
                      context,
                    ).loadString('LICENSE', cache: false);
                  }),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试'),
                ),
              ],
            );
          }
          return SelectableText(
            snapshot.data!.trim(),
            key: const Key('project-license-text'),
            style: const TextStyle(fontSize: 13, height: 1.6),
          );
        },
      ),
    ],
  );
}

class MusingsPage extends StatelessWidget {
  const MusingsPage({super.key});

  @override
  Widget build(BuildContext context) => const _InfoPage(
    pageKey: Key('musings-page'),
    title: '碎碎念',
    children: [
      _StorySection(
        title: '名字来自《玉响》',
        text:
            '项目取名自动画《玉响》（Tamayura / たまゆら）。'
            '这是一部以摄影为线索、描绘日常与成长的动画：'
            '喜欢摄影的沢渡楓来到父亲的故乡——广岛县竹原市，'
            '用相机记录身边的风景，也与朋友们一起寻找生活中的小小幸福。',
      ),
      _StorySection(
        title: '把美好的瞬间，留在身边',
        text:
            '摄影让转瞬即逝的光、风景和笑容有了可以重逢的地方。'
            '玉响这个项目也是为此而生：让记录下来的美好，在自己的设备之间轻松流动。'
            '无论照片留在哪一台设备里，都希望你能随时翻到、取回，再分享给在意的人。',
      ),
      _StorySection(
        title: '50728，一个小小的纪念',
        text:
            '沢渡（さわたり）楓（ふう）的生日是 1995 年 7 月 28 日。'
            '取年份末位的「5」和月日的「0728」，组成了玉响的默认端口 '
            '${LanEndpoint.defaultPort}。每一次连接，也藏着对这部动画的一点喜欢。',
      ),
    ],
  );
}

class _InfoPage extends StatelessWidget {
  const _InfoPage({
    required this.pageKey,
    required this.title,
    required this.children,
  });

  final Key pageKey;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: pageKey,
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 30),
            children: children,
          ),
        ),
      ),
    ),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    elevation: 0,
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    child: child,
  );
}

class _StorySection extends StatelessWidget {
  const _StorySection({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: _InfoCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(text, style: const TextStyle(fontSize: 15, height: 1.9)),
          ],
        ),
      ),
    ),
  );
}
