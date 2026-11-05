// 职责: 验证图片参考素材上传到用户配置的对象存储桶并取得可访问地址。
// 关联文件:
//   lib/shared/services/ai/image/reference_storage.dart
//   lib/shared/services/object_storage/service.dart
//   lib/shared/models/object_storage_config.dart
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/object_storage_config.dart';
import 'package:reveric/shared/services/ai/image/reference_storage.dart';
import 'package:reveric/shared/services/object_storage/service.dart';

void main() {
  late AppDatabase database;
  late Directory directory;
  late File reference;

  setUp(() async {
    database = AppDatabase.forTest(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp(
      'image-reference-storage-',
    );
    reference = File('${directory.path}/reference.png');
    await reference.writeAsBytes([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'uses the configured bucket and public URL for local references',
    () async {
      final requests = <String>[];
      final storage = ObjectStorageService(
        database: database,
        client: () => MockClient((request) async {
          requests.add(
            '${request.method} ${request.url.host}${request.url.path}',
          );
          return http.Response('', request.method == 'HEAD' ? 404 : 200);
        }),
      );
      await storage.save(
        const ObjectStorageConfig(
          endpoint: 'https://s3.example.com',
          region: 'us-east-1',
          bucket: 'my-images',
          accessKeyId: 'access',
          secretAccessKey: 'secret',
          keyPrefix: 'reveric/references',
          publicBaseUrl: 'https://cdn.example.com/images',
        ),
      );

      final url = await ImageReferenceStorageService(storage)
          .upload(reference.path);

      expect(url.host, 'cdn.example.com');
      expect(url.path, startsWith('/images/reveric/references/'));
      expect(requests, [
        startsWith('HEAD my-images.s3.example.com/reveric/references/'),
        startsWith('PUT my-images.s3.example.com/reveric/references/'),
      ]);
    },
  );
}
