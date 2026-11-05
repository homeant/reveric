// 职责: 检测本机 Codex CLI 的 ChatGPT 登录态并展示重新检测入口。
// 关联文件:
//   lib/shared/services/ai/codex_cli/app_server.dart
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/i18n.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../components/reveric_button.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../services/ai/codex_cli/app_server.dart';
import '../../theme/theme.dart';

Future<void> checkCodexCliLogin() async {
  final server = await CodexAppServer.start();
  await server.close();
}

class CodexCliConnection extends HookWidget {
  const CodexCliConnection({super.key, this.checkLogin = checkCodexCliLogin});

  final Future<void> Function() checkLogin;

  @override
  Widget build(BuildContext context) {
    final revision = useState(0);
    final request = useMemoized(checkLogin, [checkLogin, revision.value]);
    final snapshot = useFuture(request);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final loading = snapshot.connectionState != ConnectionState.done;
    final status = loading
        ? LocaleKeys.settingsCodexCliChecking
        : switch (snapshot.error) {
            CodexCliException(reason: CodexCliFailure.not_found) =>
              LocaleKeys.settingsCodexCliMissing,
            CodexCliException(reason: CodexCliFailure.not_signed_in) =>
              LocaleKeys.settingsCodexCliNotSignedIn,
            null => LocaleKeys.settingsCodexCliReady,
            _ => LocaleKeys.settingsCodexCliUnavailable,
          };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(status),
          style: typo.ui.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.sm),
        Text(
          context.t(LocaleKeys.settingsCodexCliHint),
          style: typo.uiSmall.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: RevericSpacing.sm),
        RevericButton.secondary(
          label: context.t(LocaleKeys.settingsCodexCheckLogin),
          loading: loading,
          onPressed: () => revision.value++,
        ),
      ],
    );
  }
}
