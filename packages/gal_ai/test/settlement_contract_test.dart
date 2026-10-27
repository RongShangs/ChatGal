import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 捕获请求的假 provider：只记录 prompt，回一个固定 JSON。
class _CaptureProvider implements DialogueProvider {
  String? lastUserPrompt;

  @override
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String delta)? onDelta,
  }) async {
    for (final m in request.messages) {
      if (m['role'] == 'user') lastUserPrompt = '${m['content']}';
    }
    return ProviderResult.ok(
      response: AIResponse(
        protocolVersion: 1,
        segments: const [],
        suggestedReplies: const [],
      ),
      rawText: '{"deltas": {"好感": 1}}',
    );
  }
}

SceneDef _sceneWithSettlement() => SceneDef.fromJson(
      {
        'displayName': 'test',
        'settlement': [
          {
            'var': '好感',
            'prompt': '有没有更亲近',
            'maxAbsDelta': 2,
          },
          {
            'var': '信任',
            'prompt': '有没有更信任',
            'maxAbsDelta': 1,
          },
        ],
      },
      id: 's1',
    );

void main() {
  group('结算请求契约：必须写明 deltas 外层结构', () {
    test('prompt 里含 deltas 示例、变量键名与单次上限', () async {
      final capture = _CaptureProvider();
      final provider = DialogueSettlementProvider(capture);
      final proposal = await provider.propose(
        sessionId: 's',
        scene: _sceneWithSettlement(),
        world: WorldSnapshot(
          variables: const {'好感': 50, '信任': 40, 'day': 1},
          characters: const {},
          eventHistory: const {},
          story: const {},
          presentation: const {},
          rngState: 1,
        ),
        evidence: const SettlementEvidence(
          owner: 'jj',
          sceneId: 's1',
          sceneName: 'test',
          day: 1,
          shortTerm: ['她笑了'],
          state: {'好感': 50, '信任': 40},
          audience: ['jj'],
        ),
      );

      final prompt = capture.lastUserPrompt!;
      // 解析器强制要求 {"deltas": {...}}：请求里必须给出外层结构示例
      expect(prompt, contains('"deltas"'));
      expect(prompt, contains('好感'));
      expect(prompt, contains('信任'));
      // 每变量的单次上限要进请求，模型才理解评分尺度
      expect(prompt, contains('上限 2'));
      expect(prompt, contains('上限 1'));
      // 解析成功
      expect(proposal, isNotNull);
      expect(proposal!.deltas['好感'], 1);
    });

    test('模型返回扁平结构（无 deltas）→ 判解析失败 → null（按零增量）', () async {
      final capture = _CaptureProvider();
      // 覆盖 rawText 返回扁平结构
      final flat = _FlatProvider('{"好感": 1}');
      final provider = DialogueSettlementProvider(flat);
      final proposal = await provider.propose(
        sessionId: 's',
        scene: _sceneWithSettlement(),
        world: WorldSnapshot(
          variables: const {'好感': 50, '信任': 40, 'day': 1},
          characters: const {},
          eventHistory: const {},
          story: const {},
          presentation: const {},
          rngState: 1,
        ),
        evidence: const SettlementEvidence(
          owner: 'jj',
          sceneId: 's1',
          sceneName: 'test',
          day: 1,
          shortTerm: ['她笑了'],
          state: {'好感': 50, '信任': 40},
          audience: ['jj'],
        ),
      );
      // 扁平结构没有 deltas 外层 → 解析失败 → null
      expect(proposal, isNull);
      expect(capture.lastUserPrompt, isNull); // flat provider 没记 prompt
    });
  });
}

class _FlatProvider implements DialogueProvider {
  _FlatProvider(this.raw);
  final String raw;

  @override
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String delta)? onDelta,
  }) async {
    return ProviderResult.ok(
      response: AIResponse(
        protocolVersion: 1,
        segments: const [],
        suggestedReplies: const [],
      ),
      rawText: raw,
    );
  }
}
