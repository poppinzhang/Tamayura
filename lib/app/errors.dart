import 'dart:io';
import 'package:flutter/services.dart';
import 'package:grpc/grpc.dart';

String describeError(Object error) {
  if (error is FormatException) return error.message;
  if (error is PlatformException) return error.message ?? '系统操作失败，请重试';
  if (error is GrpcError) {
    if (error.code == StatusCode.notFound) return '对端文件已删除或不可访问，请刷新相册';
    if (error.code == StatusCode.failedPrecondition) {
      return '对端共享目录不可用，请在对端重新选择目录并刷新';
    }
    if (error.code == StatusCode.dataLoss) return '文件未传输完整，请重试';
    return '暂时连不上这台设备，请确认两台设备在同一局域网，且对端应用已打开';
  }
  if (error is SocketException) return '无法连接局域网，请检查 Wi-Fi 后重试';
  if (error is FileSystemException) return '文件保存失败，请检查剩余空间和目录权限';
  return '操作未完成，请重试。$error';
}
