import 'package:gal_protocol/gal_protocol.dart';

enum ProviderStatus {
  ok,
  cancelled,
  timeout,
  rateLimited,
  offline,
  invalid,
  formatError,
}

class ProviderResult {
  const ProviderResult.ok({
    required this.response,
    this.rawText,
  })  : status = ProviderStatus.ok,
        error = null;

  const ProviderResult.failed({
    required this.status,
    required this.error,
    this.rawText,
  }) : response = null;

  final ProviderStatus status;
  final AIResponse? response;
  final String? error;
  final String? rawText;

  bool get ok => status == ProviderStatus.ok && response != null;
}

class GenerateRequest {
  const GenerateRequest({
    required this.messages,
    this.maxTokens,
    this.stream = false,
  });

  final List<Map<String, String>> messages;

  /// 覆盖供应商配置里的输出上限。推理型模型会把额度耗在思考上导致正文为空，
  /// 提炼/结算这类「短输出」请求可以要一个更大的额度。
  final int? maxTokens;

  /// 是否要求网络流式（SSE）。仅影响传输；解析仍在整段结束后做一次。
  final bool stream;
}
