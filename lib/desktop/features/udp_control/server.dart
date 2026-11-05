// 职责: 提供仅本机监听的桌面 UDP 界面控制协议，转发 Flutter 语义、指针和截图操作。
// 关联文件:
//   lib/desktop/features/udp_control/file_dialog.dart
//   lib/main.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/logger/app_logger.dart';
import 'file_dialog.dart';

final _log = AppLogger.forModule('UdpControl');
const defaultUdpControlPort = 8765;

/// Omit the option to leave the listener completely disabled.
int? udpControlPortFromArgs(List<String> args) {
  const prefix = '--udp-control-port=';
  final matches = args
      .where(
        (arg) => arg == '--udp-control' || arg.startsWith('--udp-control-port'),
      )
      .toList();
  if (matches.isEmpty) {
    return null;
  }
  if (matches.length != 1) {
    throw FormatException('Specify UDP control only once');
  }
  if (matches.single == '--udp-control') {
    return defaultUdpControlPort;
  }
  if (!matches.single.startsWith(prefix)) {
    throw FormatException('Use --udp-control or $prefix<port>');
  }
  final port = int.tryParse(matches.single.substring(prefix.length));
  if (port == null || port < 1 || port > 65535) {
    throw FormatException('UDP control port must be between 1 and 65535');
  }
  return port;
}

/// JSON datagrams use `{id, method, params}` and return `{id, ok, result|error}`.
/// `snapshot` returns semantic node IDs and actions; `tap`, `longPress`,
/// `scroll`, and `setText` target those IDs. `tapAt` and `scrollAt` use logical
/// Flutter coordinates. `capture` and oversized responses return a transfer
/// ID; `read` retrieves base64 chunks. `fileDialog.arm` intercepts the next
/// picker, then `fileDialog.pending` and `fileDialog.complete` choose paths.
class UdpAppControl {
  UdpAppControl(this.port, {required this.captureKey});

  final int port;
  final GlobalKey captureKey;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  SemanticsHandle? _semanticsHandle;
  UdpFileDialog? _fileDialog;
  FileSelectorPlatform? _originalFileSelector;
  final Map<int, Uint8List> _transfers = {};
  int _nextTransfer = 1;
  int _nextPointer = 1;
  Future<void> _requestQueue = Future.value();

  @visibleForTesting
  int? get boundPort => _socket?.port;

  @visibleForTesting
  Future<Object?> dispatchForTesting(
    String method,
    Map<String, dynamic> params,
  ) => _dispatch(method, params);

  Future<void> start() async {
    if (_socket != null) {
      throw StateError('UDP control is already running');
    }
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    _socket = socket;
    _semanticsHandle = SemanticsBinding.instance.ensureSemantics();
    _originalFileSelector = FileSelectorPlatform.instance;
    _fileDialog = UdpFileDialog(_originalFileSelector!);
    FileSelectorPlatform.instance = _fileDialog!;
    _subscription = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          final request = datagram!;
          _requestQueue = _requestQueue.then((_) => _handle(request));
        }
      }
    });
    _log.info('UDP control listening on 127.0.0.1:$port');
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _socket?.close();
    _socket = null;
    _fileDialog?.dispose();
    if (_originalFileSelector != null) {
      FileSelectorPlatform.instance = _originalFileSelector!;
    }
    _fileDialog = null;
    _originalFileSelector = null;
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
    _transfers.clear();
  }

  Future<void> _handle(Datagram datagram) async {
    Object? id;
    try {
      if (datagram.data.length > 48000) {
        throw FormatException('Request exceeds 48000 bytes');
      }
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('Request must be a JSON object');
      }
      id = decoded['id'];
      final method = decoded['method'];
      final params = decoded['params'] ?? <String, dynamic>{};
      if (method is! String || params is! Map<String, dynamic>) {
        throw FormatException('method and params must be a string and object');
      }
      final result = await _dispatch(method, params);
      _reply(datagram, {'id': id, 'ok': true, 'result': result});
    } catch (error, stackTrace) {
      _log.error('UDP request failed', error: error, stackTrace: stackTrace);
      _reply(datagram, {
        'id': id,
        'ok': false,
        'error': {
          'type': error.runtimeType.toString(),
          'message': error.toString(),
        },
      });
    }
  }

  void _reply(Datagram datagram, Map<String, Object?> response) {
    var bytes = Uint8List.fromList(utf8.encode(jsonEncode(response)));
    if (bytes.length > 24000) {
      final transfer = _store(bytes);
      bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({'id': response['id'], 'ok': true, 'result': transfer}),
        ),
      );
    }
    _socket?.send(bytes, datagram.address, datagram.port);
  }

  Map<String, Object> _store(Uint8List bytes) {
    if (_transfers.length == 4) {
      _transfers.remove(_transfers.keys.first);
    }
    final id = _nextTransfer++;
    _transfers[id] = bytes;
    return {'transfer': id, 'bytes': bytes.length, 'chunkSize': 12000};
  }

  Future<Object?> _dispatch(String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'snapshot':
        return _snapshot();
      case 'tap':
      case 'longPress':
      case 'scroll':
      case 'setText':
        return _semanticAction(method, params);
      case 'tapAt':
        return _tapAt(params);
      case 'scrollAt':
        return _scrollAt(params);
      case 'capture':
        return _capture();
      case 'read':
        return _read(params);
      case 'fileDialog.arm':
        _fileDialog!.arm();
        return _fileDialog!.pending;
      case 'fileDialog.pending':
        return _fileDialog!.pending;
      case 'fileDialog.cancel':
        _fileDialog!.cancel();
        return _fileDialog!.pending;
      case 'fileDialog.complete':
        final paths = params['paths'];
        if (paths is! List || paths.any((path) => path is! String)) {
          throw FormatException(
            'paths must be an array of strings; [] cancels',
          );
        }
        _fileDialog!.complete(paths.cast<String>());
        return {'completed': true};
      default:
        throw ArgumentError.value(
          method,
          'method',
          'Unknown UDP control method',
        );
    }
  }

  Future<Map<String, Object>> _snapshot() async {
    await _nextFrame();
    final views = <Map<String, Object>>[];
    for (final view in RendererBinding.instance.renderViews) {
      final nodes = <Map<String, Object?>>[];
      final root = view.owner?.semanticsOwner?.rootSemanticsNode;
      if (root != null) {
        void visit(SemanticsNode node, int? parent) {
          final data = node.getSemanticsData();
          nodes.add({'id': node.id, 'parent': parent, ...data.toJson()});
          node.visitChildren((child) {
            visit(child, node.id);
            return true;
          });
        }

        visit(root, null);
      }
      views.add({'viewId': view.flutterView.viewId, 'nodes': nodes});
    }
    return {'views': views};
  }

  Future<Map<String, Object>> _semanticAction(
    String method,
    Map<String, dynamic> params,
  ) async {
    await _nextFrame();
    final id = _integer(params, 'node');
    final view = _view(params);
    final owner = view.owner?.semanticsOwner;
    var node = owner?.getSemanticsNode(id);
    if (node == null) {
      throw StateError(
        'Semantic node $id is no longer present; refresh snapshot',
      );
    }
    final action = switch (method) {
      'tap' => SemanticsAction.tap,
      'longPress' => SemanticsAction.longPress,
      'setText' => SemanticsAction.setText,
      'scroll' => _scrollAction(params),
      _ => throw ArgumentError.value(method),
    };
    if (method == 'setText' && !node.getSemanticsData().hasAction(action)) {
      final data = node.getSemanticsData();
      if (data.flagsCollection.isTextField &&
          data.hasAction(SemanticsAction.tap)) {
        owner!.performAction(id, SemanticsAction.tap);
        await _nextFrame();
        node = owner.getSemanticsNode(id);
      }
    }
    if (node == null || !node.getSemanticsData().hasAction(action)) {
      throw StateError('Node $id does not support ${action.name}');
    }
    Object? argument;
    if (method == 'setText') {
      argument = _string(params, 'text');
    }
    owner!.performAction(id, action, argument);
    await _nextFrame();
    final updated = owner.getSemanticsNode(id);
    return {
      'node': id,
      'action': action.name,
      if (method == 'setText') 'value': updated?.getSemanticsData().value ?? '',
    };
  }

  SemanticsAction _scrollAction(Map<String, dynamic> params) =>
      switch (_string(params, 'direction')) {
        'up' => SemanticsAction.scrollUp,
        'down' => SemanticsAction.scrollDown,
        'left' => SemanticsAction.scrollLeft,
        'right' => SemanticsAction.scrollRight,
        final other => throw ArgumentError.value(other, 'direction'),
      };

  Map<String, Object> _tapAt(Map<String, dynamic> params) {
    final point = _point(params);
    final viewId = _view(params).flutterView.viewId;
    final pointer = _nextPointer++;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        viewId: viewId,
        pointer: pointer,
        position: point,
        kind: PointerDeviceKind.mouse,
      ),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(
        viewId: viewId,
        pointer: pointer,
        position: point,
        kind: PointerDeviceKind.mouse,
      ),
    );
    return {'x': point.dx, 'y': point.dy};
  }

  Map<String, Object> _scrollAt(Map<String, dynamic> params) {
    final point = _point(params);
    final viewId = _view(params).flutterView.viewId;
    final dx = _number(params, 'dx');
    final dy = _number(params, 'dy');
    GestureBinding.instance.handlePointerEvent(
      PointerScrollEvent(
        viewId: viewId,
        position: point,
        scrollDelta: ui.Offset(dx, dy),
      ),
    );
    return {'x': point.dx, 'y': point.dy, 'dx': dx, 'dy': dy};
  }

  Future<Map<String, Object>> _capture() async {
    await _nextFrame();
    final boundary = captureKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      throw StateError('Flutter application is not ready for capture');
    }
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('PNG encoding failed');
      }
      return {..._store(data.buffer.asUint8List()), 'mimeType': 'image/png'};
    } finally {
      image.dispose();
    }
  }

  Map<String, Object> _read(Map<String, dynamic> params) {
    final id = _integer(params, 'transfer');
    final chunk = _integer(params, 'chunk');
    final data = _transfers[id];
    if (data == null) {
      throw StateError('Transfer $id is unavailable');
    }
    if (chunk < 0 || chunk * 12000 >= data.length) {
      throw RangeError.value(chunk, 'chunk');
    }
    final start = chunk * 12000;
    final end = (start + 12000).clamp(0, data.length);
    return {
      'transfer': id,
      'chunk': chunk,
      'data': base64Encode(data.sublist(start, end)),
    };
  }

  RenderView _view(Map<String, dynamic> params) {
    final views = RendererBinding.instance.renderViews;
    final requestedId = params['viewId'];
    if (requestedId != null && requestedId is! int) {
      throw FormatException('viewId must be an integer');
    }
    for (final view in views) {
      if (requestedId == null || view.flutterView.viewId == requestedId) {
        return view;
      }
    }
    throw StateError('Flutter view is unavailable: $requestedId');
  }

  ui.Offset _point(Map<String, dynamic> params) =>
      ui.Offset(_number(params, 'x'), _number(params, 'y'));

  int _integer(Map<String, dynamic> params, String name) {
    final value = params[name];
    if (value is! int) {
      throw FormatException('$name must be an integer');
    }
    return value;
  }

  double _number(Map<String, dynamic> params, String name) {
    final value = params[name];
    if (value is! num || !value.isFinite) {
      throw FormatException('$name must be a finite number');
    }
    return value.toDouble();
  }

  String _string(Map<String, dynamic> params, String name) {
    final value = params[name];
    if (value is! String) {
      throw FormatException('$name must be a string');
    }
    return value;
  }

  Future<void> _nextFrame() async {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 5),
    );
  }
}
