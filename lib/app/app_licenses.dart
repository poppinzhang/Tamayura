import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerBrandingLicenses() {
  LicenseRegistry.addLicense(() async* {
    const directory = 'assets/branding/hibiki/license';
    final attribution = await rootBundle.loadString(
      '$directory/ATTRIBUTION.txt',
    );
    final license = await rootBundle.loadString('$directory/Nagino-OFL.txt');
    yield LicenseEntryWithLineBreaks([
      'Nagino (響 icon)',
    ], '$attribution\n\n$license');
  });
}
