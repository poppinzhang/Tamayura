import 'package:material_ui/material_ui.dart';

import '../app/app_info.dart';
import '../app/endpoint.dart';
import '../l10n/app_locale.dart';
import 'app_icons.dart';

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
    title: context.l10n.aboutTitle,
    children: [
      const SizedBox(height: 12),
      Icon(
        AppIcons.logo,
        size: 64,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(height: 16),
      Text(
        context.l10n.appTitle,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 12),
      Text(
        context.l10n.aboutSummary,
        textAlign: TextAlign.center,
        style: const TextStyle(height: 1.7),
      ),
      const SizedBox(height: 28),
      _InfoCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.aboutVersion,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              FutureBuilder<AppVersion>(
                future: _version,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return Text(context.l10n.aboutReadingVersion);
                  }
                  if (snapshot.hasError || !snapshot.hasData) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(context.l10n.aboutVersionUnavailable),
                        TextButton.icon(
                          key: const Key('retry-app-version'),
                          onPressed: () => setState(() {
                            _version = Future.sync(widget.loadVersion);
                          }),
                          icon: const Icon(AppIcons.refresh),
                          label: Text(context.l10n.commonRetry),
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
          leading: const Icon(AppIcons.code),
          title: Text(context.l10n.aboutProjectLicense),
          subtitle: const Text('Apache-2.0'),
          trailing: const Icon(AppIcons.next),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const ProjectLicensePage()),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _InfoCard(
        child: ListTile(
          key: const Key('dependency-licenses-entry'),
          leading: const Icon(AppIcons.license),
          title: Text(context.l10n.aboutThirdPartyLicenses),
          subtitle: Text(context.l10n.aboutThirdPartyLicensesSubtitle),
          trailing: const Icon(AppIcons.next),
          onTap: () => showLicensePage(
            context: context,
            applicationName: context.l10n.appTitle,
          ),
        ),
      ),
      const SizedBox(height: 12),
      _InfoCard(
        child: ListTile(
          key: const Key('musings-entry'),
          leading: const Icon(AppIcons.camera),
          title: Text(context.l10n.aboutMusings),
          subtitle: Text(context.l10n.aboutMusingsSubtitle),
          trailing: const Icon(AppIcons.next),
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
      Text(context.l10n.licenseIntro, style: const TextStyle(height: 1.7)),
      const SizedBox(height: 20),
      FutureBuilder<String>(
        future: _license,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Text(context.l10n.licenseReading);
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.licenseUnavailable),
                TextButton.icon(
                  key: const Key('retry-project-license'),
                  onPressed: () => setState(() {
                    _license = DefaultAssetBundle.of(
                      context,
                    ).loadString('LICENSE', cache: false);
                  }),
                  icon: const Icon(AppIcons.refresh),
                  label: Text(context.l10n.commonRetry),
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
  Widget build(BuildContext context) => _InfoPage(
    pageKey: const Key('musings-page'),
    title: context.l10n.aboutMusings,
    children: [
      _StorySection(
        title: context.l10n.musingNameTitle,
        text: context.l10n.musingNameText,
      ),
      _StorySection(
        title: context.l10n.musingMomentsTitle,
        text: context.l10n.musingMomentsText,
      ),
      _StorySection(
        title: context.l10n.musingPortTitle,
        text: context.l10n.musingPortText(LanEndpoint.defaultPort),
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
