import 'dart:io';
import 'package:flutter/services.dart';
import 'package:grpc/grpc.dart';
import '../l10n/app_locale.dart';
import '../network/downloader.dart' show TransferStalled;

String describeError(Object error) {
  final text = AppLocale.strings;
  if (error is TransferStalled) return text.errorPeerStalled;
  if (error is FormatException) return error.message;
  if (error is PlatformException) {
    // Codes shared by all platforms read the same in every interface language;
    // other native messages are already localized by the platform.
    return switch (error.code) {
      'DIR_OVERLAP' => text.errorFolderOverlap,
      'FILE_CHANGED' => text.errorFileChanged,
      'SCAN_CANCELLED' => text.errorScanCancelled,
      _ => error.message ?? text.errorSystemOperation,
    };
  }
  if (error is GrpcError) {
    if (error.code == StatusCode.notFound) return text.errorPeerFileMissing;
    if (error.code == StatusCode.failedPrecondition) {
      return text.errorPeerFolderUnavailable;
    }
    if (error.code == StatusCode.dataLoss) return text.errorTransferIncomplete;
    return text.errorPeerUnreachable;
  }
  if (error is SocketException) return text.errorNetworkUnavailable;
  if (error is FileSystemException) return text.errorFileSave;
  return text.errorUnknown('$error');
}
