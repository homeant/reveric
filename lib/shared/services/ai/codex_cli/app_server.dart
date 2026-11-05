// 职责: 启动本机 Codex app-server，并通过标准输入输出交换请求、事件和工具结果。
// 关联文件:
//   lib/shared/agent/client/codex_cli_client.dart
//   lib/shared/services/ai/image/codex_cli.dart

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

enum CodexCliFailure { unsupported_platform, not_found, not_signed_in, other }

class CodexCliException implements Exception {
  const CodexCliException(this.message, {this.reason = CodexCliFailure.other});
  final String message;
  final CodexCliFailure reason;

  @override
  String toString() => 'Codex CLI: $message';
}

class CodexAppServer {
  CodexAppServer._(this._process) {
    _stdoutSubscription = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: _onError, onDone: _onDone);
    _stderrSubscription = _process.stderr.transform(utf8.decoder).listen((
      chunk,
    ) {
      _diagnostic = '$_diagnostic$chunk';
      if (_diagnostic.length > 8192) {
        _diagnostic = _diagnostic.substring(_diagnostic.length - 8192);
      }
    });
  }

  final Process _process;
  late final StreamSubscription<String> _stdoutSubscription;
  late final StreamSubscription<String> _stderrSubscription;
  final Queue<Map<String, dynamic>> _messages = Queue();
  Completer<void>? _waiting;
  Object? _failure;
  String _diagnostic = '';
  int _nextId = 0;

  static bool get supportedPlatform => Platform.isMacOS;

  static Future<String> executable() async {
    if (!supportedPlatform) {
      throw const CodexCliException(
        'Only macOS supports this provider',
        reason: CodexCliFailure.unsupported_platform,
      );
    }
    final home = Platform.environment['HOME'];
    final candidates = <String>[
      for (final path in (Platform.environment['PATH'] ?? '').split(':'))
        if (path.isNotEmpty) '$path/codex',
      '/opt/homebrew/bin/codex',
      '/usr/local/bin/codex',
      if (home != null) '$home/.local/bin/codex',
      '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        return candidate;
      }
    }
    throw const CodexCliException(
      'Codex CLI was not found',
      reason: CodexCliFailure.not_found,
    );
  }

  static Future<CodexAppServer> start({String? executablePath}) async {
    final path = executablePath ?? await executable();
    final Process process;
    try {
      process = await Process.start(path, ['app-server']);
    } on ProcessException catch (error) {
      throw CodexCliException('Could not start Codex CLI: ${error.message}');
    }
    final server = CodexAppServer._(process);
    try {
      await server.request('initialize', {
        'clientInfo': {'name': 'reveric', 'version': '1.0'},
        'capabilities': {'experimentalApi': true},
      });
      server.notify('initialized');
      final account = await server.request('account/read', {});
      final signedIn = account['account'];
      if (signedIn is! Map || signedIn['type'] != 'chatgpt') {
        throw const CodexCliException(
          'Codex CLI must be signed in using ChatGPT',
          reason: CodexCliFailure.not_signed_in,
        );
      }
      return server;
    } catch (_) {
      await server.close();
      rethrow;
    }
  }

  void _onLine(String line) {
    try {
      _messages.add(jsonDecode(line) as Map<String, dynamic>);
      _waiting?.complete();
      _waiting = null;
    } catch (error) {
      _onError(error);
    }
  }

  void _onError(Object error) {
    _failure = error;
    _waiting?.complete();
    _waiting = null;
  }

  void _onDone() {
    _failure = CodexCliException('app-server exited: $_diagnostic');
    _waiting?.complete();
    _waiting = null;
  }

  Future<Map<String, dynamic>> next({
    Duration timeout = const Duration(minutes: 3),
  }) async {
    while (_messages.isEmpty) {
      if (_failure case final failure?) {
        throw CodexCliException('$failure');
      }
      final waiting = _waiting ??= Completer<void>();
      await waiting.future.timeout(timeout);
    }
    return _messages.removeFirst();
  }

  void send(Map<String, dynamic> message) {
    _process.stdin.writeln(jsonEncode(message));
  }

  void notify(String method, [Map<String, dynamic>? params]) {
    final message = <String, dynamic>{'method': method};
    if (params != null) {
      message['params'] = params;
    }
    send(message);
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = ++_nextId;
    send({'id': id, 'method': method, 'params': params});
    final deferred = <Map<String, dynamic>>[];
    while (true) {
      final message = await next(timeout: const Duration(seconds: 30));
      if (message['id'] == id) {
        for (final event in deferred.reversed) {
          _messages.addFirst(event);
        }
        if (message['error'] case final error?) {
          throw CodexCliException('$method failed: $error');
        }
        return (message['result'] as Map).cast<String, dynamic>();
      }
      deferred.add(message);
    }
  }

  Future<void> close() async {
    _failure = const CodexCliException('app-server closed');
    _waiting?.complete();
    _waiting = null;
    _process.kill();
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
  }
}
