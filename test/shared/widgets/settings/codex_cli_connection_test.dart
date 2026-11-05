// 职责: 验证 Codex CLI 登录检测区分缺少命令、未登录和已登录状态。
// 关联文件:
//   lib/shared/widgets/settings/codex_cli_connection.dart
//   lib/shared/services/ai/codex_cli/app_server.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/services/ai/codex_cli/app_server.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/codex_cli_connection.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets('recheck distinguishes missing CLI and missing login', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        assetLoader: const MergingAssetLoader(),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(
                body: CodexCliConnection(
                  checkLogin: () async {
                    attempts++;
                    if (attempts == 1) {
                      throw const CodexCliException(
                        'missing',
                        reason: CodexCliFailure.not_found,
                      );
                    }
                    if (attempts == 2) {
                      throw const CodexCliException(
                        'not signed in',
                        reason: CodexCliFailure.not_signed_in,
                      );
                    }
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Codex CLI was not found'), findsOneWidget);
    await tester.tap(find.text('Check login'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Codex CLI is not signed in'), findsOneWidget);
    await tester.tap(find.text('Check login'));
    await tester.pumpAndSettle();
    expect(find.text('Codex CLI is signed in with ChatGPT'), findsOneWidget);
    expect(attempts, 3);
  });
}
