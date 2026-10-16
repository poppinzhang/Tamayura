import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tamayura/app/app_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mockPackage({required String version, required String buildNumber}) {
    PackageInfo.setMockInitialValues(
      appName: 'Tamayura',
      packageName: 'dev.tamayura.app',
      version: version,
      buildNumber: buildNumber,
      buildSignature: '',
    );
  }

  test(
    'loads installed version and build number rather than source defaults',
    () async {
      mockPackage(version: '9.8.7', buildNumber: '654');

      final info = await AppVersion.load();

      expect(info.version, '9.8.7');
      expect(info.buildNumber, '654');
      expect(info.displayVersion, '9.8.7+654');
    },
  );

  test('accepts prerelease versions and dotted Apple build numbers', () async {
    mockPackage(version: ' 1.2.3-beta.4 ', buildNumber: ' 12.3.4 ');

    expect((await AppVersion.load()).displayVersion, '1.2.3-beta.4+12.3.4');
  });

  test(
    'reports empty or malformed package metadata as a readable error',
    () async {
      for (final (version, buildNumber) in [
        ('', '3'),
        ('   ', '3'),
        ('0.0.2', ''),
        ('unknown', '3'),
        ('1..2', '3'),
        ('1.2.3', 'unknown'),
        ('1.2.3', '-1'),
      ]) {
        mockPackage(version: version, buildNumber: buildNumber);

        await expectLater(
          AppVersion.load(),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              '无法读取应用版本信息，请重试',
            ),
          ),
          reason: '$version+$buildNumber',
        );
      }
    },
  );
}
