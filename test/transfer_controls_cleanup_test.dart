import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/ui/transfer_widgets.dart';

void main() {
  final item = MediaView(
    id: 'a',
    deviceId: 'phone',
    name: 'a.jpg',
    mimeType: 'image/jpeg',
    size: 100,
    modified: DateTime(2026),
    thumbnail: Uint8List(0),
  );
  testWidgets(
    'pause and discard are distinct controls and retained bytes are visible',
    (tester) async {
      var pauses = 0, discards = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferControls(
              item: item,
              transfer: TransferView(
                progress: .4,
                receivedBytes: 40,
                totalBytes: 100,
              ),
              onDownload: () {},
              onCancel: () => pauses++,
              onDiscard: () => discards++,
              onShare: () {},
              onOpen: () {},
            ),
          ),
        ),
      );
      expect(find.textContaining('已暂存约'), findsOneWidget);
      await tester.tap(find.text('暂停下载'));
      expect(pauses, 1);
      expect(discards, 0);
      await tester.tap(find.text('取消并删除'));
      expect(discards, 1);
    },
  );
  testWidgets(
    'failed cleanup can retry deletion without offering to resume the task',
    (tester) async {
      var discards = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferControls(
              item: item,
              transfer: TransferView(
                progress: .4,
                status: TransferStatus.discarded,
                error: '暂存清理失败，请重试删除任务',
              ),
              onDownload: () {},
              onCancel: () {},
              onDiscard: () => discards++,
              onShare: () {},
              onOpen: () {},
            ),
          ),
        ),
      );
      expect(find.byKey(Key('retry-${item.key}')), findsNothing);
      await tester.tap(find.text('删除任务并释放空间'));
      expect(discards, 1);
    },
  );
}
