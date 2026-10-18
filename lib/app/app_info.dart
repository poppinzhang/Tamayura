import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/app_locale.dart';

/// Version metadata from the installed app, including build-time overrides.
class AppVersion {
  const AppVersion(this.version, this.buildNumber);

  final String version;
  final String buildNumber;

  String get displayVersion => '$version+$buildNumber';

  static Future<AppVersion> load() async {
    final info = await PackageInfo.fromPlatform();
    final version = info.version.trim();
    final buildNumber = info.buildNumber.trim();
    if (!RegExp(
          r'^\d+(?:\.\d+)*(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$',
        ).hasMatch(version) ||
        !RegExp(r'^\d+(?:\.\d+)*$').hasMatch(buildNumber)) {
      throw FormatException(AppLocale.strings.errorVersionUnreadable);
    }
    return AppVersion(version, buildNumber);
  }
}
