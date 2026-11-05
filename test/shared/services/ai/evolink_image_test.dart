// 职责: 验证 EvoLink 生图提交、桶中参考图地址、异步任务恢复和结果落盘。
// 关联文件:
//   lib/shared/services/ai/image/evolink.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/models/image/channels.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

const _model = 'doubao-seedream-5.0-pro';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==';
const _image = 'data:image/png;base64,$_png';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  final provider = aiProviderBuiltinById('openai')!.copyWith(
    id: 'evolink-test',
    type: 'evolink',
    enabled: true,
    apiKey: 'test-key',
    imageModels: imageModelsForProvider('evolink'),
  );

  setUp(() async {
    support = await Directory.systemTemp.createTemp('evolink-image-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              {
                'getApplicationSupportDirectory',
                'getTemporaryDirectory',
              }.contains(call.method)
              ? support.path
              : null,
        );
    await RevericPaths.initialize();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await support.delete(recursive: true);
  });

  test(
    'submits Seedream ratio and tier, records task ID, then saves image',
    () async {
      final calls = <String>[];
      final result = await http.runWithClient(
        () => AiImageGenerationService(provider, model: _model).generateImage(
          'a scene',
          aspectRatio: '16:9',
          resolution: '2K',
          onSubmitted: (id) async {
            calls.add('submitted:$id');
          },
        ),
        () => MockClient((request) async {
          calls.add('${request.method}:${request.url.path}');
          expect(request.headers['authorization'], 'Bearer test-key');
          if (request.method == 'POST') {
            expect(jsonDecode(request.body), {
              'model': _model,
              'prompt': 'a scene',
              'size': '16:9',
              'quality': '2K',
              'n': 1,
            });
            return http.Response(
              jsonEncode({'id': 'task-1', 'status': 'pending'}),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'status': 'completed',
              'result_data': [
                {'url': _image},
              ],
            }),
            200,
          );
        }),
      );
      expect(calls, [
        'POST:/v1/images/generations',
        'submitted:task-1',
        'GET:/v1/tasks/task-1',
      ]);
      expect(result.localFilePath, isNotNull);
      expect(await File(result.localFilePath!).exists(), isTrue);
    },
  );

  test('sends uploaded bucket URLs as references', () async {
    final uploaded = <String>[];
    await http.runWithClient(
      () =>
          AiImageGenerationService(
            provider,
            model: _model,
            referenceUploader: (image) async {
              uploaded.add(image);
              return Uri.parse(
                'https://bucket.example.com/references/image.png',
              );
            },
          ).editImages(
            'edit the scene',
            imageData: [_image],
            aspectRatio: '1:1',
            resolution: '2K',
          ),
      () => MockClient((request) async {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['image_urls'], [
            'https://bucket.example.com/references/image.png',
          ]);
          return http.Response(jsonEncode({'id': 'task-2'}), 200);
        }
        return http.Response(
          jsonEncode({
            'status': 'completed',
            'result_data': [
              {'url': _image},
            ],
          }),
          200,
        );
      }),
    );
    expect(uploaded, [_image]);
  });

  test('maps chat character image sizes to EvoLink aspect ratios', () async {
    for (final (size, ratio) in [('1024x1024', '1:1'), ('864x1536', '9:16')]) {
      await http.runWithClient(
        () => AiImageGenerationService(
          provider,
          model: _model,
        ).generateImage('a character portrait', size: size),
        () => MockClient((request) async {
          if (request.method == 'POST') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['size'], ratio);
            expect(body['quality'], '2K');
            return http.Response(jsonEncode({'id': 'task-$ratio'}), 200);
          }
          return http.Response(
            jsonEncode({
              'status': 'completed',
              'result_data': [
                {'url': _image},
              ],
            }),
            200,
          );
        }),
      );
    }
  });

  test(
    'keeps task ID when polling fails and resumes without resubmitting',
    () async {
      final paths = <String>[];
      final service = AiImageGenerationService(provider, model: _model);
      await http.runWithClient(
        () async {
          final error = await service
              .generateImage('a scene')
              .then<Object>(
                (_) => throw StateError('Expected poll failure'),
                onError: (error) => error,
              );
          expect(error, isA<AiImageFetchException>());
          expect((error as AiImageFetchException).providerTaskId, 'task-3');
        },
        () => MockClient((request) async {
          paths.add(request.url.path);
          return request.method == 'POST'
              ? http.Response(jsonEncode({'id': 'task-3'}), 200)
              : http.Response('unavailable', 503);
        }),
      );
      await http.runWithClient(
        () => service.resumeResult('task-3'),
        () => MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(
            jsonEncode({
              'status': 'completed',
              'result_data': [
                {'url': _image},
              ],
            }),
            200,
          );
        }),
      );
      expect(paths, [
        '/v1/images/generations',
        '/v1/tasks/task-3',
        '/v1/tasks/task-3',
      ]);
    },
  );
}
