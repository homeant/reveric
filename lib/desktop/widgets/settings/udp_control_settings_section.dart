// 职责: 在桌面通用设置中显示 UDP 控制的即时开关、监听地址与启动错误。
// 关联文件:
//   lib/desktop/features/udp_control/controller.dart
//   lib/shared/widgets/settings/settings_section_widgets.dart
//   lib/desktop/widgets/settings/settings_general_section.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';

import '../../../shared/components/reveric_switch.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/settings/settings_section_widgets.dart';
import '../../features/udp_control/controller.dart';

class UdpControlSettingsSection extends StatelessWidget {
  const UdpControlSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = UdpControlController.instance;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final colors = RevericTheme.colorsOf(context);
        final typo = RevericTheme.typographyOf(context);
        return SettingsSection(
          titleKey: LocaleKeys.settingsUdpControlTitle,
          descriptionKey: LocaleKeys.settingsUdpControlDescription,
          child: SettingsCard(
            children: [
              SettingsRow(
                labelKey: LocaleKeys.settingsUdpControlEnabled,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '127.0.0.1:${controller.port}',
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    ),
                    RevericSwitch(
                      value: controller.enabled,
                      onChanged: controller.busy ? null : controller.setEnabled,
                    ),
                  ],
                ),
              ),
              if (controller.lastError != null)
                Text(
                  context.t(LocaleKeys.settingsUdpControlFailed),
                  style: typo.uiSmall.copyWith(color: colors.error),
                ),
            ],
          ),
        );
      },
    );
  }
}
