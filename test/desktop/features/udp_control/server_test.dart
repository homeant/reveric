// 职责: 验证 UDP 控制能读写真实 Flutter 输入状态，并保持文件选择与协议边界正确。
// 关联文件:
//   lib/desktop/features/udp_control/server.dart
//   lib/desktop/features/udp_control/file_dialog.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/udp_control/file_dialog.dart';
import 'package:reveric/desktop/features/udp_control/controller.dart';
import 'package:reveric/desktop/features/udp_control/server.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('launch option accepts only a valid explicit port', () {
    expect(udpControlPortFromArgs([]), isNull);
    expect(udpControlPortFromArgs(['--udp-control']), defaultUdpControlPort);
    expect(udpControlPortFromArgs(['--udp-control-port=8765']), 8765);
    expect(
      () => udpControlPortFromArgs(['--udp-control-port=0']),
      throwsFormatException,
    );
    expect(
      () => udpControlPortFromArgs(['--udp-control-port']),
      throwsFormatException,
    );
    expect(
      () => udpControlPortFromArgs([
        '--udp-control-port=8765',
        '--udp-control-port=8766',
      ]),
      throwsFormatException,
    );
  });

  test(
    'armed file picker accepts a Chinese-named file and cancellation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'udp-control-test-',
      );
      final file = File('${directory.path}/陈启.txt');
      await file.writeAsString('content');
      final dialog = UdpFileDialog(FileSelectorPlatform.instance);
      try {
        dialog.arm();
        final selected = dialog.openFile();
        expect(dialog.pending['kind'], 'file');
        dialog.complete([file.path]);
        expect((await selected)?.path, file.path);

        dialog.arm();
        final canceled = dialog.openFile();
        dialog.complete([]);
        expect(await canceled, isNull);
      } finally {
        dialog.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('UDP replies preserve request IDs and errors', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final service = UdpAppControl(0, captureKey: GlobalKey());
    await service.start();
    final client = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    try {
      var response = Completer<Map<String, dynamic>>();
      final subscription = client.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = client.receive();
          if (datagram != null) {
            response.complete(
              jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>,
            );
          }
        }
      });
      client.send(
        utf8.encode(jsonEncode({'id': 6, 'method': 'fileDialog.pending'})),
        InternetAddress.loopbackIPv4,
        service.boundPort!,
      );
      final pending = await response.future.timeout(const Duration(seconds: 3));
      expect(pending['id'], 6);
      expect(pending['ok'], true);
      expect((pending['result'] as Map)['armed'], false);

      response = Completer<Map<String, dynamic>>();
      client.send(
        utf8.encode(jsonEncode({'id': 7, 'method': 'unknown'})),
        InternetAddress.loopbackIPv4,
        service.boundPort!,
      );
      final reply = await response.future.timeout(const Duration(seconds: 3));
      expect(reply['id'], 7);
      expect(reply['ok'], false);
      expect((reply['error'] as Map)['message'], contains('unknown'));
      await subscription.cancel();
    } finally {
      client.close();
      await service.close();
    }
  });

  test(
    'large UDP replies are transferred in datagrams below 8192 bytes',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final service = UdpAppControl(0, captureKey: GlobalKey());
      await service.start();
      final client = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final responses = StreamController<Map<String, dynamic>>.broadcast();
      final subscription = client.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = client.receive()) != null) {
          responses.add(
            jsonDecode(utf8.decode(datagram!.data)) as Map<String, dynamic>,
          );
        }
      });

      Future<Map<String, dynamic>> request(Map<String, Object> body) async {
        final reply = responses.stream.first.timeout(
          const Duration(seconds: 3),
        );
        client.send(
          utf8.encode(jsonEncode(body)),
          InternetAddress.loopbackIPv4,
          service.boundPort!,
        );
        return reply;
      }

      try {
        final largeMethod = 'x' * 8100;
        final first = await request({'id': 8, 'method': largeMethod});
        expect(first['id'], 8);
        expect(first['ok'], true);
        final transfer = first['result'] as Map<String, dynamic>;
        final bytes = <int>[];
        for (
          var chunk = 0;
          bytes.length < (transfer['bytes'] as int);
          chunk++
        ) {
          final part = await request({
            'id': 9,
            'method': 'read',
            'params': {'transfer': transfer['transfer'], 'chunk': chunk},
          });
          expect(utf8.encode(jsonEncode(part)).length, lessThan(8192));
          expect(part['ok'], true);
          bytes.addAll(base64Decode((part['result'] as Map)['data'] as String));
        }
        final original = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        expect(original['id'], 8);
        expect(original['ok'], false);
        expect((original['error'] as Map)['message'], contains(largeMethod));

        final pending = await request({
          'id': 10,
          'method': 'fileDialog.pending',
        });
        expect(pending['ok'], true);
        expect(pending['id'], 10);
      } finally {
        await subscription.cancel();
        await responses.close();
        client.close();
        await service.close();
      }
    },
  );

  test('settings toggle starts, stops, and persists UDP control', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final controller = UdpControlController.instance;
    await controller.initialize(captureKey: GlobalKey(), commandLinePort: 0);
    try {
      expect(controller.enabled, true);
      await controller.setEnabled(false);
      expect(controller.enabled, false);
      var preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('udp_control_enabled'), false);

      await controller.setEnabled(true);
      expect(controller.enabled, true);
      preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('udp_control_enabled'), true);
    } finally {
      await controller.setEnabled(false);
    }
  });

  testWidgets('setText updates the real controller and rendered field', (
    tester,
  ) async {
    final controller = TextEditingController();
    var taps = 0;
    final captureKey = GlobalKey();
    final service = UdpAppControl(0, captureKey: captureKey);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: captureKey,
          child: Scaffold(
            body: Column(
              children: [
                TextField(controller: controller),
                ElevatedButton(
                  onPressed: () => taps++,
                  child: const Text('Click'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    try {
      final snapshot = service.dispatchForTesting('snapshot', {});
      await tester.pump();
      final views = (await snapshot as Map<String, Object>)['views'] as List;
      final nodes = (views.first as Map)['nodes'] as List;
      final field = nodes.cast<Map>().firstWhere(
        (node) => (node['flags'] as List).contains('isTextField'),
      );

      final write = service.dispatchForTesting('setText', {
        'node': field['id'],
        'text': '陈启',
      });
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final result = await write as Map;
      expect(result['value'], '陈启');
      expect(controller.text, '陈启');
      expect(find.text('陈启'), findsOneWidget);

      final button = tester.getCenter(find.byType(ElevatedButton));
      await service.dispatchForTesting('tapAt', {
        'x': button.dx,
        'y': button.dy,
      });
      await tester.pump();
      expect(taps, 1);

      final capture = service.dispatchForTesting('capture', {});
      await tester.pump();
      final transfer = await tester.runAsync(() => capture) as Map;
      expect(transfer['mimeType'], 'image/png');
      final chunk =
          await service.dispatchForTesting('read', {
                'transfer': transfer['transfer'],
                'chunk': 0,
              })
              as Map;
      expect(base64Decode(chunk['data'] as String), isNotEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      controller.dispose();
    }
  });
}
