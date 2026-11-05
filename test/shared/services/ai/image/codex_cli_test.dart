// 职责: 验证 Codex CLI 生图客户端传入参考图，并只使用完整回合的最终图片结果。
// 关联文件:
//   lib/shared/services/ai/image/codex_cli.dart
//   lib/shared/services/ai/codex_cli/app_server.dart
//   lib/shared/models/ai_provider.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/image/client.dart';
import 'package:reveric/shared/services/ai/image/codex_cli.dart';

const _fakeServer = '''#!/usr/bin/python3
import json, os, sys
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    ident = request.get('id')
    if method == 'initialize':
        print(json.dumps({'id': ident, 'result': {}}), flush=True)
    elif method == 'account/read':
        print(json.dumps({'id': ident, 'result': {'account': {'type': 'chatgpt'}}}), flush=True)
    elif method == 'thread/start':
        print(json.dumps({'id': ident, 'result': {'thread': {'id': 'thread-1'}}}), flush=True)
    elif method == 'turn/start':
        inputs = request['params']['input']
        assert inputs[1]['type'] == 'localImage'
        with open(inputs[1]['path'], 'rb') as image:
            assert image.read() == bytes([1, 2, 3])
        if 'force-fallback' not in inputs[0]['text']:
            output = os.path.join(os.path.dirname(inputs[1]['path']), 'result.png')
            with open(output, 'wb') as image:
                image.write(bytes([7, 8, 9]))
        print(json.dumps({'id': ident, 'result': {'turn': {'id': 'turn-1'}}}), flush=True)
        for result in ['AQID', 'BAUG']:
            print(json.dumps({'method': 'item/completed', 'params': {'item': {
                'type': 'imageGeneration', 'status': 'completed', 'result': result
            }}}), flush=True)
        print(json.dumps({'method': 'turn/completed', 'params': {}}), flush=True)
''';

void main() {
  test('reference edit uses the image saved by Codex', () async {
    final temp = await Directory.systemTemp.createTemp('codex-cli-image-test-');
    addTearDown(() => temp.delete(recursive: true));
    final executable = '${temp.path}/fake-server';
    await File(executable).writeAsString(_fakeServer);
    final chmod = await Process.run('/bin/chmod', ['+x', executable]);
    expect(chmod.exitCode, 0);

    final provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'codex-cli-test',
      type: AiProviderType.codex_cli.name,
      apiKey: '',
      models: ['gpt-6-luna'],
      imageModels: ['gpt-image-2'],
    );
    final client = CodexCliImageClient(provider, executablePath: executable);
    final result = await client.generate(
      const ImageGenerationRequest(
        prompt: 'Turn it red',
        model: 'gpt-image-2',
        images: ['data:image/png;base64,AQID'],
      ),
    );
    expect(result.imageBase64, 'BwgJ');
  }, skip: Platform.isWindows);

  test('uses the final completed image item when no file was saved', () async {
    final temp = await Directory.systemTemp.createTemp('codex-cli-image-test-');
    addTearDown(() => temp.delete(recursive: true));
    final executable = '${temp.path}/fake-server';
    await File(executable).writeAsString(_fakeServer);
    final chmod = await Process.run('/bin/chmod', ['+x', executable]);
    expect(chmod.exitCode, 0);
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'codex-cli-test',
      type: AiProviderType.codex_cli.name,
      apiKey: '',
      models: ['gpt-6-luna'],
      imageModels: ['gpt-image-2'],
    );
    final result =
        await CodexCliImageClient(
          provider,
          executablePath: executable,
        ).generate(
          const ImageGenerationRequest(
            prompt: 'force-fallback',
            model: 'gpt-image-2',
            images: ['data:image/png;base64,AQID'],
          ),
        );
    expect(result.imageBase64, 'BAUG');
  }, skip: Platform.isWindows);
}
