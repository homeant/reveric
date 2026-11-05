// 职责: 将 Reveric 的 Agent 消息和工具回合接到本机 Codex app-server 聊天。
// 关联文件:
//   lib/shared/agent/client.dart
//   lib/shared/agent/message.dart
//   lib/shared/services/ai/codex_cli/app_server.dart
//   lib/shared/services/ai/provider_initializer.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../services/ai/codex_cli/app_server.dart';
import '../agent_config.dart';
import '../agent_tool_dispatcher.dart';
import '../client.dart';
import '../message.dart';

class CodexCliClient implements ProviderClient {
  CodexCliClient({required this.model, this.executablePath});

  final String model;
  final String? executablePath;
  CodexAppServer? _server;
  Directory? _workspace;
  final Map<String, int> _pendingCalls = {};
  bool _cancelled = false;
  bool _running = false;

  static Future<List<String>> fetchModels({String? executablePath}) async {
    final server = await CodexAppServer.start(executablePath: executablePath);
    try {
      final result = await server.request('model/list', {});
      final data = result['data'] as List? ?? const [];
      return [
        for (final item in data)
          if (item is Map && item['id'] is String && item['hidden'] != true)
            item['id'] as String,
      ];
    } finally {
      await server.close();
    }
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    if (_running) {
      throw StateError('Codex CLI client already has an active stream');
    }
    _running = true;
    _cancelled = false;
    try {
      if (_server == null) {
        await _start(messages, tools ?? const []);
      } else {
        _submitToolResults(messages);
      }
      if (_cancelled) {
        await _close();
        yield StreamCancelled();
        return;
      }
      final server = _server!;
      while (true) {
        final event = await server.next();
        final method = event['method'];
        final params = event['params'] as Map? ?? const {};
        if (method == 'item/agentMessage/delta') {
          final delta = params['delta'];
          if (delta is String && delta.isNotEmpty) {
            yield TextDelta(delta);
          }
        } else if (method == 'item/tool/call') {
          final call = params.cast<String, dynamic>();
          final callId = call['callId'] as String;
          final requestId = event['id'];
          if (requestId is! int) {
            throw const CodexCliException('Tool call has no request id');
          }
          _pendingCalls[callId] = requestId;
          yield ToolCallDelta(
            callId: callId,
            toolName: call['tool'] as String,
            arguments: (call['arguments'] as Map).cast<String, dynamic>(),
          );
          yield StreamComplete(finishReason: StreamFinishReason.toolCalls);
          return;
        } else if (method == 'turn/completed') {
          yield StreamComplete(finishReason: StreamFinishReason.stop);
          await _close();
          return;
        } else if (method == 'turn/failed') {
          throw CodexCliException('Turn failed: $params');
        } else if (event.containsKey('id') && method != null) {
          throw CodexCliException('Unhandled app-server request: $method');
        }
      }
    } catch (_) {
      await _close();
      if (_cancelled) {
        yield StreamCancelled();
        return;
      }
      rethrow;
    } finally {
      _running = false;
    }
  }

  Future<void> _start(List<AgentMessage> messages, List<ToolDef> tools) async {
    final workspace = await Directory.systemTemp.createTemp('reveric-codex-');
    _workspace = workspace;
    final server = await CodexAppServer.start(executablePath: executablePath);
    _server = server;
    if (_cancelled) {
      return;
    }
    final instructions = messages
        .where((message) => message.role == AgentMessageRole.system)
        .map((message) => message.content)
        .join('\n\n');
    final thread = await server.request('thread/start', {
      'model': model,
      'cwd': workspace.path,
      'ephemeral': true,
      'sandbox': 'read-only',
      'approvalPolicy': 'never',
      'serviceName': 'reveric',
      'developerInstructions': [
        instructions,
        'Use the provided dynamic tools for application data. Do not run '
            'shell commands or read local files for this conversation.',
      ].where((text) => text.isNotEmpty).join('\n\n'),
      'dynamicTools': [
        for (final tool in tools)
          {
            'type': 'function',
            'name': tool.name,
            'description': tool.description,
            'inputSchema': tool.inputSchema,
          },
      ],
    });
    final threadId = (thread['thread'] as Map)['id'] as String;
    final input = <Map<String, dynamic>>[
      {'type': 'text', 'text': _conversationText(messages)},
    ];
    final latestUser = messages
        .where((m) => m.role == AgentMessageRole.user)
        .lastOrNull;
    if (latestUser != null) {
      var imageIndex = 0;
      for (final image in latestUser.blocks.whereType<ImageBlock>()) {
        final bytes = base64Decode(
          image.data.replaceFirst(RegExp(r'^data:[^,]+,'), ''),
        );
        final path = '${workspace.path}/input_${imageIndex++}.png';
        await File(path).writeAsBytes(bytes);
        input.add({'type': 'localImage', 'path': path});
      }
    }
    await server.request('turn/start', {'threadId': threadId, 'input': input});
  }

  static String _conversationText(List<AgentMessage> messages) {
    final transcript = StringBuffer();
    for (final message in messages) {
      if (message.role == AgentMessageRole.system) {
        continue;
      }
      if (message.type == AgentMessageType.tool_result) {
        for (final result in message.blocks.whereType<ToolResultBlock>()) {
          transcript.writeln('Tool ${result.toolName} result:');
          for (final block in result.content.whereType<TextBlock>()) {
            transcript.writeln(block.text);
          }
        }
      } else {
        transcript.writeln(
          '${message.role == AgentMessageRole.assistant ? 'Assistant' : 'User'}: '
          '${message.content}',
        );
      }
    }
    return transcript.toString();
  }

  void _submitToolResults(List<AgentMessage> messages) {
    final server = _server!;
    for (final message in messages.where(
      (message) => message.type == AgentMessageType.tool_result,
    )) {
      for (final result in message.blocks.whereType<ToolResultBlock>()) {
        final requestId = _pendingCalls.remove(result.toolCallId);
        if (requestId == null) {
          continue;
        }
        server.send({
          'id': requestId,
          'result': {
            'success': !result.isError,
            'contentItems': [
              for (final block in result.content.whereType<TextBlock>())
                {'type': 'inputText', 'text': block.text},
            ],
          },
        });
      }
    }
    if (_pendingCalls.isNotEmpty) {
      throw const CodexCliException('A Codex tool call has no matching result');
    }
  }

  Future<void> _close() async {
    final server = _server;
    _server = null;
    _pendingCalls.clear();
    await server?.close();
    final workspace = _workspace;
    _workspace = null;
    if (workspace != null && await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  }

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    final text = StringBuffer();
    final calls = <ToolCall>[];
    StreamFinishReason? reason;
    await for (final event in chatStream(
      messages: messages,
      tools: tools,
      options: options,
    )) {
      switch (event) {
        case TextDelta():
          text.write(event.text);
        case ToolCallDelta():
          calls.add(
            ToolCall(
              callId: event.callId,
              toolName: event.toolName,
              arguments: event.arguments,
            ),
          );
        case StreamComplete():
          reason = event.finishReason;
        case StreamCancelled():
          throw const CodexCliException('Request cancelled');
        case StreamError():
          throw CodexCliException(event.message);
        default:
          break;
      }
    }
    return ChatResponse(
      text: text.toString(),
      toolCalls: calls,
      finishReason: reason,
    );
  }

  @override
  void cancel() {
    _cancelled = true;
    if (_running) {
      final server = _server;
      if (server != null) {
        unawaited(server.close());
      }
    } else {
      unawaited(_close());
    }
  }
}
