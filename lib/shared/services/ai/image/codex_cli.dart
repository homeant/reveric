// 职责: 通过本机 Codex app-server 聊天生成或编辑图片，并提取完成的图片结果。
// 关联文件:
//   lib/shared/services/ai/codex_cli/app_server.dart
//   lib/shared/services/ai/image/client.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json

import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';

import '../../../localization/locale_keys.dart';
import '../../../models/ai_provider.dart';
import '../codex_cli/app_server.dart';
import '../image.dart';
import 'client.dart';

class CodexCliImageClient extends ImageClient {
  CodexCliImageClient(super.config, {this.executablePath});

  final String? executablePath;

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    if (request.model != 'gpt-image-2') {
      throw AiImageGenerationException(
        tr(LocaleKeys.aiImageGenerationFailed),
        code: AiImageErrorCode.param,
        debugMessage: 'Codex CLI image model is gpt-image-2',
      );
    }
    final workspace = await Directory.systemTemp.createTemp('reveric-image-');
    CodexAppServer? server;
    try {
      server = await CodexAppServer.start(executablePath: executablePath);
      final chatModels = config.availableModels;
      if (chatModels.isEmpty) {
        throw const CodexCliException('A Codex chat model is required');
      }
      final model = chatModels.contains('gpt-6-luna')
          ? 'gpt-6-luna'
          : chatModels.first;
      final thread = await server.request('thread/start', {
        'model': model,
        'cwd': workspace.path,
        'ephemeral': true,
        'sandbox': 'workspace-write',
        'approvalPolicy': 'never',
        'serviceName': 'reveric',
      });
      final input = <Map<String, dynamic>>[];
      final prompt = StringBuffer('\$imagegen ${request.prompt}');
      if (request.size case final size?) {
        prompt.write(' Requested size: $size.');
      }
      if (request.quality case final quality?) {
        prompt.write(' Requested quality: $quality.');
      }
      final outputPath = '${workspace.path}/result.png';
      prompt.write(' Save the finished image as $outputPath.');
      input.add({'type': 'text', 'text': prompt.toString()});
      for (var i = 0; i < request.images.length; i++) {
        final source = await imageInputAsDataUri(request.images[i]);
        final data = UriData.parse(source);
        final extension = data.mimeType == 'image/jpeg' ? 'jpg' : 'png';
        final path = '${workspace.path}/reference_$i.$extension';
        await File(path).writeAsBytes(data.contentAsBytes());
        input.add({'type': 'localImage', 'path': path});
      }
      await server.request('turn/start', {
        'threadId': (thread['thread'] as Map)['id'],
        'input': input,
      });
      String? image;
      while (true) {
        final event = await server.next(timeout: const Duration(minutes: 5));
        final method = event['method'];
        final params = event['params'] as Map? ?? const {};
        if (method == 'item/completed') {
          final item = params['item'] as Map?;
          if (item?['type'] == 'imageGeneration' &&
              item?['status'] == 'completed' &&
              item?['result'] is String) {
            image = item!['result'] as String;
          }
        } else if (method == 'turn/completed') {
          final output = File(outputPath);
          if (await output.exists()) {
            if (await FileSystemEntity.type(outputPath, followLinks: false) !=
                FileSystemEntityType.file) {
              throw const CodexCliException(
                'Codex saved image is not a regular file',
              );
            }
            if (await output.length() > 64 * 1024 * 1024) {
              throw const CodexCliException('Codex saved image is too large');
            }
            final bytes = await output.readAsBytes();
            if (bytes.isNotEmpty) {
              return AiImageGenerationResult(imageBase64: base64Encode(bytes));
            }
          }
          if (image == null) {
            throw const CodexCliException('Codex finished without an image');
          }
          final base64 = image.replaceFirst(RegExp(r'^data:image/[^,]+,'), '');
          base64Decode(base64);
          return AiImageGenerationResult(imageBase64: base64);
        } else if (method == 'turn/failed') {
          throw CodexCliException('Image turn failed: $params');
        } else if (event.containsKey('id') && method != null) {
          throw CodexCliException('Unhandled app-server request: $method');
        }
      }
    } on CodexCliException catch (error) {
      throw AiImageGenerationException(
        tr(switch (error.reason) {
          CodexCliFailure.not_found => LocaleKeys.aiCodexCliMissing,
          CodexCliFailure.not_signed_in => LocaleKeys.aiCodexImageAuthFailed,
          _ => LocaleKeys.aiImageGenerationFailed,
        }),
        debugMessage: error.message,
        code: error.reason == CodexCliFailure.not_signed_in
            ? AiImageErrorCode.auth
            : null,
      );
    } finally {
      await server?.close();
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    }
  }
}
