// 职责: 显式启用时验证 Reveric 的 Codex CLI 聊天和生图客户端能使用真实 ChatGPT 登录态。
// 关联文件:
//   lib/shared/agent/client/codex_cli_client.dart
//   lib/shared/services/ai/image/codex_cli.dart
//   lib/shared/models/ai_provider.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/client/codex_cli_client.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/image/client.dart';
import 'package:reveric/shared/services/ai/image/codex_cli.dart';

void main() {
  final enabled =
      Platform.isMacOS &&
      Platform.environment['REVERIC_CODEX_CLI_SMOKE'] == '1';

  test(
    'real Codex CLI model catalog contains Luna',
    () async {
      expect(await CodexCliClient.fetchModels(), contains('gpt-6-luna'));
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'real Codex CLI chat completes through Reveric client',
    () async {
      HttpOverrides.global = null;
      final client = CodexCliClient(model: 'gpt-6-luna');
      addTearDown(client.cancel);
      final events = await client
          .chatStream(
            messages: [
              AgentMessage.user(
                id: 'smoke-user',
                content: 'Reply with exactly: reveric-cli-dart-ok',
              ),
            ],
          )
          .toList();
      expect(
        events.whereType<TextDelta>().map((e) => e.text).join(),
        contains('reveric-cli-dart-ok'),
      );
      expect(
        events.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.stop,
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'real Codex CLI calls a Reveric dynamic tool and resumes',
    () async {
      HttpOverrides.global = null;
      final client = CodexCliClient(model: 'gpt-6-luna');
      addTearDown(client.cancel);
      final user = AgentMessage.user(
        id: 'tool-user',
        content:
            'Call ReadProbe with value ping. Reply with the tool result text only.',
      );
      const tool = ToolDef(
        name: 'ReadProbe',
        description: 'Return a value from Reveric.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'value': {'type': 'string'},
          },
          'required': ['value'],
        },
      );
      final first = await client
          .chatStream(messages: [user], tools: [tool])
          .toList();
      final call = first.whereType<ToolCallDelta>().single;
      expect(call.toolName, 'ReadProbe');
      expect(call.arguments['value'], 'ping');
      final result = AgentMessage(
        id: 'tool-result',
        role: AgentMessageRole.user,
        type: AgentMessageType.tool_result,
        blocks: [
          ToolResultBlock(
            toolCallId: call.callId,
            toolName: call.toolName,
            content: const [TextBlock('reveric-cli-tool-ok')],
          ),
        ],
      );
      final second = await client
          .chatStream(messages: [user, result], tools: [tool])
          .toList();
      expect(
        second.whereType<TextDelta>().map((e) => e.text).join(),
        contains('reveric-cli-tool-ok'),
      );
      expect(
        second.whereType<StreamComplete>().single.finishReason,
        StreamFinishReason.stop,
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'real Codex CLI image generation returns decodable bytes',
    () async {
      HttpOverrides.global = null;
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        id: 'codex-cli-smoke',
        type: AiProviderType.codex_cli.name,
        apiKey: '',
        models: ['gpt-6-luna'],
        imageModels: ['gpt-image-2'],
      );
      final result = await CodexCliImageClient(provider).generate(
        const ImageGenerationRequest(
          prompt:
              'A single solid green circle on a white square background. No text.',
          model: 'gpt-image-2',
        ),
      );
      expect(img.decodeImage(base64Decode(result.imageBase64!)), isNotNull);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
