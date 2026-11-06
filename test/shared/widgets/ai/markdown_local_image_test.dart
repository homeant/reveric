// 职责: 验证聊天正文中的应用内图片路径按本地文件加载。
// 关联文件:
//   lib/shared/widgets/ai/markdown_text.dart
//   lib/shared/utils/storage_paths.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/ai/markdown_text.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  const stored = 'file_workspaces/work/sessions/session/file_generated.png';
  late Directory support;
  late File imageFile;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('ai-markdown-image-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => support.path);
    await RevericPaths.initialize();
    imageFile = File(p.join(support.path, stored));
    await imageFile.parent.create(recursive: true);
    await imageFile.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await support.delete(recursive: true);
  });

  testWidgets('renders a session snapshot with FileImage', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(
      () => precacheImage(
        FileImage(imageFile),
        tester.element(find.byType(SizedBox).first),
      ).timeout(const Duration(seconds: 10)),
    );
    await tester.pumpWidget(_wrap('![Generated]($stored)'));
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<FileImage>());
    expect((image.image as FileImage).file.path, imageFile.path);
    await tester.pump();
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((rendered) => rendered.image != null),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('rejects traversal in a local image path', (tester) async {
    await tester.pumpWidget(_wrap('![Outside](file_workspaces/../secret.png)'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

Widget _wrap(String content) => MaterialApp(
  theme: RevericThemeData.reveric.toThemeData(),
  home: RevericTheme(
    data: RevericThemeData.reveric,
    child: Scaffold(
      body: SingleChildScrollView(
        child: AiMarkdownText(
          content,
          style: RevericThemeData.reveric.typography.body,
        ),
      ),
    ),
  ),
);
