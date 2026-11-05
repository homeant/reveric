// 职责: 验证 Codex CLI 聊天把动态工具请求交给 Reveric，并将结果送回原回合。
// 关联文件:
//   lib/shared/agent/client/codex_cli_client.dart
//   lib/shared/services/ai/codex_cli/app_server.dart
//   lib/shared/agent/message.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/client/codex_cli_client.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/services/ai/codex_cli/app_server.dart';

const _fakeServer = '''#!/usr/bin/python3
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    ident = request.get('id')
    if method == 'initialize':
        print(json.dumps({'id': ident, 'result': {}}), flush=True)
    elif method == 'account/read':
        print(json.dumps({'id': ident, 'result': {'account': {'type': 'chatgpt'}}}), flush=True)
    elif method == 'model/list':
        print(json.dumps({'id': ident, 'result': {'data': [
            {'id': 'gpt-6-luna', 'hidden': False},
            {'id': 'hidden-model', 'hidden': True}
        ]}}), flush=True)
    elif method == 'thread/start':
        assert request['params']['dynamicTools'][0]['name'] == 'ReadProbe'
        print(json.dumps({'id': ident, 'result': {'thread': {'id': 'thread-1'}}}), flush=True)
    elif method == 'turn/start':
        print(json.dumps({'id': ident, 'result': {'turn': {'id': 'turn-1'}}}), flush=True)
        if 'hang' not in request['params']['input'][0]['text']:
            print(json.dumps({'id': 99, 'method': 'item/tool/call', 'params': {
                'callId': 'call-1', 'tool': 'ReadProbe', 'arguments': {'value': 'ping'}
            }}), flush=True)
    elif ident == 99:
        assert request['result']['contentItems'][0]['text'] == 'probe-result'
        print(json.dumps({'method': 'item/agentMessage/delta', 'params': {
            'delta': 'probe-result'
        }}), flush=True)
        print(json.dumps({'method': 'turn/completed', 'params': {}}), flush=True)
''';

void main() {
  late Directory temp;
  late String executable;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('codex-cli-test-');
    executable = '${temp.path}/fake-server';
    await File(executable).writeAsString(_fakeServer);
    final chmod = await Process.run('/bin/chmod', ['+x', executable]);
    expect(chmod.exitCode, 0);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('reads visible model IDs from app-server', () async {
    expect(await CodexCliClient.fetchModels(executablePath: executable), [
      'gpt-6-luna',
    ]);
  }, skip: Platform.isWindows);

  test('rejects a CLI without a ChatGPT login', () async {
    final source = await File(executable).readAsString();
    await File(
      executable,
    ).writeAsString(source.replaceFirst("{'type': 'chatgpt'}", 'None'));
    await expectLater(
      CodexAppServer.start(executablePath: executable),
      throwsA(
        isA<CodexCliException>().having(
          (error) => error.reason,
          'reason',
          CodexCliFailure.not_signed_in,
        ),
      ),
    );
  }, skip: Platform.isWindows);

  test('bridges a dynamic tool result into the same Codex turn', () async {
    final client = CodexCliClient(
      model: 'gpt-6-luna',
      executablePath: executable,
    );
    const tool = ToolDef(
      name: 'ReadProbe',
      description: 'Read a probe value.',
      inputSchema: {'type': 'object'},
    );
    final user = AgentMessage.user(id: 'u1', content: 'Read the probe');
    final first = await client
        .chatStream(messages: [user], tools: [tool])
        .toList();
    final call = first.whereType<ToolCallDelta>().single;
    expect(call.callId, 'call-1');
    expect(call.arguments, {'value': 'ping'});
    expect(
      first.whereType<StreamComplete>().single.finishReason,
      StreamFinishReason.toolCalls,
    );

    final result = AgentMessage(
      id: 'result-1',
      role: AgentMessageRole.user,
      type: AgentMessageType.tool_result,
      blocks: const [
        ToolResultBlock(
          toolCallId: 'call-1',
          toolName: 'ReadProbe',
          content: [TextBlock('probe-result')],
        ),
      ],
    );
    final second = await client
        .chatStream(messages: [user, result], tools: [tool])
        .toList();
    expect(
      second.whereType<TextDelta>().map((e) => e.text).join(),
      'probe-result',
    );
    expect(
      second.whereType<StreamComplete>().single.finishReason,
      StreamFinishReason.stop,
    );
    client.cancel();
  }, skip: Platform.isWindows);

  test('cancel wakes a stream waiting for Codex output', () async {
    final client = CodexCliClient(
      model: 'gpt-6-luna',
      executablePath: executable,
    );
    const tool = ToolDef(
      name: 'ReadProbe',
      description: 'Read a probe value.',
      inputSchema: {'type': 'object'},
    );
    final stream = client
        .chatStream(
          messages: [AgentMessage.user(id: 'hang', content: 'hang')],
          tools: [tool],
        )
        .toList();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    client.cancel();
    expect(
      (await stream.timeout(
        const Duration(seconds: 2),
      )).whereType<StreamCancelled>(),
      hasLength(1),
    );
  }, skip: Platform.isWindows);
}
