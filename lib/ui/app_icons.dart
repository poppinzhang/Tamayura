import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Semantic icons shared by the application, kept constant for font subsetting.
@staticIconProvider
abstract final class AppIcons {
  static const IconData album = LucideIcons.images;
  static const IconData devices = LucideIcons.monitorSmartphone;
  static const IconData settings = LucideIcons.slidersHorizontal;
  static const IconData logo = LucideIcons.aperture;

  static const IconData add = LucideIcons.plus;
  static const IconData back = LucideIcons.arrowLeftDir;
  static const IconData previous = LucideIcons.chevronLeftDir;
  static const IconData next = LucideIcons.chevronRightDir;
  static const IconData expand = LucideIcons.chevronDown;
  static const IconData close = LucideIcons.x;
  static const IconData more = LucideIcons.ellipsisVertical;
  static const IconData edit = LucideIcons.pencil;
  static const IconData delete = LucideIcons.trash2;
  static const IconData remove = LucideIcons.circleMinus;
  static const IconData sort = LucideIcons.arrowDownWideNarrow;
  static const IconData reorder = LucideIcons.arrowDownUp;
  static const IconData dragHandle = LucideIcons.gripHorizontal;
  static const IconData moveUp = LucideIcons.arrowUp;
  static const IconData moveDown = LucideIcons.arrowDown;
  static const IconData fastScroll = LucideIcons.chevronsUpDown;

  static const IconData image = LucideIcons.image;
  static const IconData video = LucideIcons.video;
  static const IconData camera = LucideIcons.camera;
  static const IconData cameraUnavailable = LucideIcons.cameraOff;
  static const IconData grid = LucideIcons.layoutGrid;
  static const IconData original = LucideIcons.hd;
  static const IconData zoomIn = LucideIcons.zoomIn;
  static const IconData zoomOut = LucideIcons.zoomOut;
  static const IconData rotateClockwise = LucideIcons.rotateCw;
  static const IconData rotateCounterclockwise = LucideIcons.rotateCcw;

  static const IconData downloads = LucideIcons.circleArrowDown;
  static const IconData download = LucideIcons.download;
  static const IconData save = LucideIcons.hardDriveDownload;
  static const IconData share = LucideIcons.share;
  static const IconData open = LucideIcons.externalLinkDir;
  static const IconData play = LucideIcons.play;
  static const IconData pause = LucideIcons.pause;
  static const IconData paused = LucideIcons.circlePause;
  static const IconData success = LucideIcons.circleCheck;
  static const IconData error = LucideIcons.circleAlert;
  static const IconData info = LucideIcons.info;
  static const IconData offline = LucideIcons.cloudOff;

  static const IconData refresh = LucideIcons.refreshCw;
  static const IconData sync = LucideIcons.refreshCw;
  static const IconData discover = LucideIcons.radar;
  static const IconData connect = LucideIcons.link2;
  static const IconData wifi = LucideIcons.wifi;
  static const IconData qrCode = LucideIcons.qrCode;
  static const IconData scanQr = LucideIcons.scanQrCode;
  static const IconData folder = LucideIcons.folderOpen;
  static const IconData sharedFolder = LucideIcons.folderSync;

  static const IconData language = LucideIcons.languages;
  static const IconData battery = LucideIcons.batteryCharging;
  static const IconData desktop = LucideIcons.monitor;
  static const IconData mobile = LucideIcons.smartphone;
  static const IconData keyboard = LucideIcons.keyboard;
  static const IconData touch = LucideIcons.pointer;
  static const IconData update = LucideIcons.download;
  static const IconData code = LucideIcons.code;
  static const IconData license = LucideIcons.fileText;
}
