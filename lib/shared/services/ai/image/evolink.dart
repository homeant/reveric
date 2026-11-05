// 职责: 提交 EvoLink Seedream 5.0 Pro 生图任务，引用对象存储中的参考图并轮询保存结果。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;

import '../../../localization/locale_keys.dart';
import '../../../models/ai_provider.dart';
import '../image.dart';
import 'client.dart';

class EvoLinkImageClient extends ImageClient {
  EvoLinkImageClient(super.config, {this.uploadReference});

  static const _model = 'doubao-seedream-5.0-pro';
  static const _pollInterval = Duration(seconds: 3);
  static const _pollTimeout = Duration(minutes: 30);
  final Future<Uri> Function(String imageData)? uploadReference;

  Uri _apiUri(String path) => Uri.parse(
    '${config.effectiveBaseUrl.replaceFirst(RegExp(r'/+$'), '')}/$path',
  );

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    if (request.model != _model) {
      throw invalidImageParameter();
    }
    final channel = validatedChannel(request)!;
    final capabilities = channel.capabilities;
    // Chat character tools request fixed pixel sizes; EvoLink accepts ratios.
    final legacyRatio = switch (request.size) {
      '1024x1024' => '1:1',
      '864x1536' => '9:16',
      _ => null,
    };
    final ratio = request.aspectRatio ?? legacyRatio ?? '1:1';
    final quality = request.resolution ?? request.quality ?? '2K';
    if (!capabilities.ratios.contains(ratio) ||
        !capabilities.resolutions.contains(quality)) {
      throw invalidImageParameter();
    }
    final expectedSize = capabilities.size(ratio, quality);
    if (request.size != null &&
        request.size != expectedSize &&
        legacyRatio != ratio) {
      throw invalidImageParameter();
    }

    final client = config.createProxyClient() ?? http.Client();
    try {
      final references = <String>[];
      for (final image in request.images) {
        final uploader = uploadReference;
        if (uploader == null) {
          throw AiImageGenerationException(
            tr(LocaleKeys.productionReferenceStorageNotConnected),
            debugMessage: 'EvoLink image reference uploader is unavailable',
          );
        }
        references.add((await uploader(image)).toString());
      }
      final task = await _requestJson(
        client,
        _apiUri('images/generations'),
        body: {
          'model': request.model,
          'prompt': request.prompt,
          'size': ratio,
          'quality': quality,
          'n': 1,
          if (references.isNotEmpty) 'image_urls': references,
        },
      );
      final id = task['id'];
      if (id is! String || id.trim().isEmpty) {
        throw _taskError(task, 'EvoLink image submission returned no task ID');
      }
      try {
        await request.onSubmitted?.call(id);
      } catch (error) {
        throw AiImageFetchException(
          '图片结果获取失败，请稍后重试。',
          providerTaskId: id,
          debugMessage: 'EvoLink task $id record failed: $error',
        );
      }
      return await _settle(client, id);
    } finally {
      client.close();
    }
  }

  @override
  Future<AiImageGenerationResult> resumeResult(String providerTaskId) async {
    final client = config.createProxyClient() ?? http.Client();
    try {
      return await _settle(client, providerTaskId);
    } finally {
      client.close();
    }
  }

  Future<AiImageGenerationResult> _settle(http.Client client, String id) async {
    final elapsed = Stopwatch()..start();
    final uri = _apiUri('tasks/${Uri.encodeComponent(id)}');
    while (elapsed.elapsed < _pollTimeout) {
      final Map<String, dynamic> task;
      try {
        task = await _requestJson(client, uri);
      } catch (error) {
        throw AiImageFetchException(
          '图片结果获取失败，请稍后重试。',
          providerTaskId: id,
          debugMessage: 'EvoLink task $id poll failed at $uri: $error',
        );
      }
      switch (task['status']) {
        case 'completed':
          final results = task['result_data'];
          final first = results is List && results.isNotEmpty
              ? results.first
              : null;
          final url = first is Map<String, dynamic> ? first['url'] : null;
          if (url is! String || url.isEmpty) {
            throw _taskError(
              task,
              'EvoLink task $id completed without image URL',
            );
          }
          return parseImageResponse({
            'data': [
              {'url': url},
            ],
          }, emptyMessage: tr(LocaleKeys.aiImageNoResult));
        case 'failed':
        case 'cancelled':
          throw _taskError(task, 'EvoLink task $id failed');
        case 'pending':
        case 'processing':
          await Future<void>.delayed(_pollInterval);
        default:
          throw _taskError(task, 'EvoLink task $id has unknown status');
      }
    }
    throw AiImageFetchException(
      '图片结果获取失败，请稍后重试。',
      providerTaskId: id,
      debugMessage: 'EvoLink task $id polling timed out after $_pollTimeout',
    );
  }

  Future<Map<String, dynamic>> _requestJson(
    http.Client client,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    final key = requireApiKey();
    final headers = {
      'Authorization': 'Bearer $key',
      'Content-Type': 'application/json',
    };
    final response =
        await (body == null
                ? client.get(uri, headers: headers)
                : client.post(uri, headers: headers, body: jsonEncode(body)))
            .timeout(imageHttpDataTimeout);
    throwForImageHttpFailure(
      uri: uri,
      statusCode: response.statusCode,
      data: response.body,
      providerId: config.id,
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null || data['success'] == false) {
      throw _taskError(data, 'EvoLink request failed at $uri');
    }
    return data;
  }

  AiImageGenerationException _taskError(
    Map<String, dynamic> data,
    String context,
  ) {
    final message = extractImageServerMessage(data);
    return AiImageGenerationException(
      imageUserMessageFromServerMessage(message) ??
          tr(LocaleKeys.aiImageGenerationFailed),
      debugMessage: '$context response=${safeImageSerializeForLog(data)}',
      code: classifyAiImageError(message),
    );
  }
}
