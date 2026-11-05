// 职责: 将生图参考图上传到用户配置的对象存储桶并返回外部可读取的地址。
// 关联文件:
//   lib/shared/services/object_storage/service.dart
//   lib/shared/providers/object_storage.dart
//   lib/shared/services/ai/image/evolink.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/file-access.md
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../localization/locale_keys.dart';
import '../../object_storage/service.dart';
import '../image.dart';
import 'client.dart';

class ImageReferenceStorageService {
  ImageReferenceStorageService(this.storage);

  final ObjectStorageService storage;

  Future<Uri> upload(String imageData) async {
    final config = await storage.load();
    if (!config.isConfigured) {
      throw AiImageGenerationException(
        tr(LocaleKeys.productionReferenceStorageNotConnected),
        debugMessage:
            'Application object storage is not configured for image references',
      );
    }

    final input = imageData.trim();
    Directory? temporaryDirectory;
    final File file;
    try {
      final candidate = File(input);
      final local =
          !input.startsWith('data:') &&
          !input.startsWith('http://') &&
          !input.startsWith('https://') &&
          await candidate.exists();
      if (!local) {
        final List<int> bytes;
        if (input.startsWith('data:')) {
          bytes = UriData.parse(input).contentAsBytes();
        } else if (input.startsWith('http://') ||
            input.startsWith('https://')) {
          final uri = Uri.parse(input);
          final client = http.Client();
          try {
            final response = await client
                .get(uri)
                .timeout(imageHttpDataTimeout);
            if (response.statusCode != HttpStatus.ok) {
              throw AiImageGenerationException(
                tr(LocaleKeys.aiImageGenerationFailed),
                debugMessage:
                    'Image reference download failed at ${safeImageUriForLog(uri)} '
                    'with HTTP ${response.statusCode}',
              );
            }
            bytes = response.bodyBytes;
          } finally {
            client.close();
          }
        } else {
          bytes = base64Decode(input);
        }
        final parent = await getTemporaryDirectory();
        temporaryDirectory = await Directory(
          p.join(parent.path, 'reveric_image_reference_'),
        ).createTemp();
        file = File(p.join(temporaryDirectory.path, 'reference'));
        await file.writeAsBytes(bytes, flush: true);
      } else {
        file = candidate;
      }
      final hash = (await sha256.bind(file.openRead()).first).toString();
      final size = await file.length();
      final header = await file.openRead(0, 12).first;
      final mimeType = 'image/${imageMimeFromBytes(header)}';
      final stored = await storage.upload(
        config,
        file: file,
        sha256: hash,
        mimeType: mimeType,
        fileSize: size,
      );
      final url = stored.url;
      if (!{'http', 'https'}.contains(url.scheme) ||
          url.host.isEmpty ||
          (stored.expiresAt != null &&
              !stored.expiresAt!.isAfter(DateTime.now().toUtc()))) {
        throw AiImageGenerationException(
          tr(LocaleKeys.aiImageGenerationFailed),
          debugMessage:
              'Object storage returned an invalid image reference URL',
        );
      }
      return url;
    } finally {
      if (temporaryDirectory != null) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  }
}
