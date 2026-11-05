// 职责: 管理桌面 UDP 控制监听的启动、关闭和下次启动恢复设置。
// 关联文件:
//   lib/desktop/features/udp_control/server.dart
//   lib/desktop/widgets/settings/udp_control_settings_section.dart
//   lib/main.dart

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/logger/app_logger.dart';
import 'server.dart';

final _log = AppLogger.forModule('UdpControl');

class UdpControlController extends ChangeNotifier {
  UdpControlController._();

  static final instance = UdpControlController._();
  static const defaultPort = defaultUdpControlPort;
  static const _enabledKey = 'udp_control_enabled';

  UdpAppControl? _server;
  GlobalKey? _captureKey;
  int _port = defaultPort;
  bool _busy = false;
  Object? _lastError;

  bool get enabled => _server != null;
  bool get busy => _busy;
  int get port => _port;
  Object? get lastError => _lastError;

  Future<void> initialize({
    required GlobalKey captureKey,
    int? commandLinePort,
  }) async {
    _captureKey = captureKey;
    _port = commandLinePort ?? defaultPort;
    final preferences = await SharedPreferences.getInstance();
    if (commandLinePort != null || preferences.getBool(_enabledKey) == true) {
      try {
        await _start();
      } catch (error, stackTrace) {
        _lastError = error;
        _log.error(
          'Failed to start UDP control',
          error: error,
          stackTrace: stackTrace,
        );
        notifyListeners();
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_busy || value == enabled) {
      return;
    }
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      if (value) {
        await _start();
      } else {
        await _server!.close();
        _server = null;
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_enabledKey, value);
    } catch (error, stackTrace) {
      _lastError = error;
      _log.error(
        'Failed to change UDP control state',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _start() async {
    final captureKey = _captureKey;
    if (captureKey == null) {
      throw StateError('UDP control has not been initialized');
    }
    final server = UdpAppControl(_port, captureKey: captureKey);
    await server.start();
    _server = server;
    notifyListeners();
  }
}
