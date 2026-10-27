class ProviderConfig {
  const ProviderConfig({
    required this.endpoint,
    required this.model,
    this.apiKey = '',
    this.temperature = 0.8,
    this.maxTokens = 2048,
    this.timeout = const Duration(seconds: 30),
  });

  final String endpoint;
  final String model;
  final String apiKey;
  final double temperature;
  final int maxTokens;
  final Duration timeout;

  Uri get chatCompletionsUri {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    return Uri.parse('$base/chat/completions');
  }
}
