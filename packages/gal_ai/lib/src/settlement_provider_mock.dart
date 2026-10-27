import 'package:gal_protocol/gal_protocol.dart';

import 'settlement_evidence.dart';
import 'transition_coordinator.dart';

/// 离线（未配置模型）与测试用的结算 provider：本幕有短期记忆证据时给
/// 第一个受控变量 +1，没证据就返回 null（不随机、不编造）。
///
/// 与命名空间无关：它从不写死变量名，所以中文 id（「戒戒好感」）照样能用。
class ChatMockSettlement implements SettlementProvider {
  const ChatMockSettlement();

  @override
  Future<SettlementProposal?> propose({
    required String sessionId,
    required SceneDef scene,
    required WorldSnapshot world,
    required SettlementEvidence evidence,
  }) async {
    final vars = [for (final b in scene.settlement) b.varId];
    if (!evidence.hasContent) return null;
    if (vars.isEmpty) return null;
    return SettlementProposal(deltas: {vars.first: 1});
  }
}
