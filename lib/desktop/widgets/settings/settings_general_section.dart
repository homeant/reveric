// 职责: 桌面端通用设置入口 — 在共享设置区加入 UDP 控制开关。
// 关联文件:
//   lib/desktop/widgets/settings/settings_dialog.dart
//   lib/shared/widgets/settings/general_settings_section.dart
//   lib/desktop/widgets/settings/udp_control_settings_section.dart
part of 'settings_dialog.dart';

class _GeneralSettingsSection extends StatelessWidget {
  const _GeneralSettingsSection();

  @override
  Widget build(BuildContext context) => const GeneralSettingsSection(
    additionalSection: UdpControlSettingsSection(),
  );
}
