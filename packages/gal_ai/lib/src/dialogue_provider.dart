import 'cancel_token.dart';
import 'provider_result.dart';

abstract class DialogueProvider {
  /// [onDelta] 在流式请求时按网络到达顺序回调增量（只含正文，不含思考块）。
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String delta)? onDelta,
  });
}
