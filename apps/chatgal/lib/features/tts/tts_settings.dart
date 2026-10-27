/// 语音朗读（云端 TTS）设置。
///
/// 走 **OpenAI 兼容** 的 `POST {base}/audio/speech`：请求体
/// `{model, input, voice, speed, response_format}`，响应体是音频字节。
/// OpenAI、SiliconFlow、Groq、部分中转站都提供这个端点，所以不需要为每家
/// 单独写适配；音色名与模型名由用户自己填（不同服务商的音色表完全不同）。
class TtsSettings {
  const TtsSettings({
    this.enabled = false,
    this.endpoint = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'tts-1',
    this.voice = 'nova',
    this.speed = 1.0,
    this.format = 'mp3',
    this.autoRead = false,
    this.skipActions = true,
    this.sampleText = '……哥，你回来了。我今天，等了很久。',
  });

  /// 总开关。关掉时聊天页不出现朗读按钮。
  final bool enabled;

  /// Base URL（与对话供应商一样带 `/v1` 这类后缀）。
  final String endpoint;
  final String apiKey;

  /// TTS 模型 ID，例如 `tts-1` / `gpt-4o-mini-tts` / `FunAudioLLM/CosyVoice2-0.5B`。
  final String model;

  /// 音色 ID，例如 `nova` / `alloy` / `FunAudioLLM/CosyVoice2-0.5B:alex`。
  final String voice;

  /// 语速倍率（1.0 = 原速）。多数服务支持 0.25–4.0。
  final double speed;

  /// 输出格式，默认 mp3（Android MediaPlayer 原生支持）。
  final String format;

  /// 新的 AI 回复到达时自动朗读。
  final bool autoRead;

  /// 朗读时跳过括号里的动作/心理描写，只读台词。
  final bool skipActions;

  /// 语音设置页里「试听」用的那句话。
  final String sampleText;

  bool get configured =>
      enabled &&
      endpoint.trim().startsWith('http') &&
      model.trim().isNotEmpty &&
      voice.trim().isNotEmpty;

  /// `POST {base}/audio/speech` 的完整 URL。
  String speechUrl() {
    final base = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    return '$base/audio/speech';
  }

  Map<String, Object?> requestBody(String input) => {
        'model': model.trim(),
        'input': input,
        'voice': voice.trim(),
        'speed': speed,
        'response_format': format,
      };

  TtsSettings copyWith({
    bool? enabled,
    String? endpoint,
    String? apiKey,
    String? model,
    String? voice,
    double? speed,
    String? format,
    bool? autoRead,
    bool? skipActions,
    String? sampleText,
  }) {
    return TtsSettings(
      enabled: enabled ?? this.enabled,
      endpoint: endpoint ?? this.endpoint,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      voice: voice ?? this.voice,
      speed: speed ?? this.speed,
      format: format ?? this.format,
      autoRead: autoRead ?? this.autoRead,
      skipActions: skipActions ?? this.skipActions,
      sampleText: sampleText ?? this.sampleText,
    );
  }

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'endpoint': endpoint,
        'apiKey': apiKey,
        'model': model,
        'voice': voice,
        'speed': speed,
        'format': format,
        'autoRead': autoRead,
        'skipActions': skipActions,
        'sampleText': sampleText,
      };

  factory TtsSettings.fromJson(Map<String, Object?> json) {
    const d = TtsSettings();
    var speed = (json['speed'] as num?)?.toDouble() ?? d.speed;
    // 越界的旧数据不能让滑块崩：夹回合法区间。
    speed = speed.clamp(0.25, 4.0);
    final format = '${json['format'] ?? d.format}'.toLowerCase();
    return TtsSettings(
      enabled: json['enabled'] as bool? ?? d.enabled,
      endpoint: '${json['endpoint'] ?? d.endpoint}',
      apiKey: '${json['apiKey'] ?? d.apiKey}',
      model: '${json['model'] ?? d.model}',
      voice: '${json['voice'] ?? d.voice}',
      speed: speed,
      format: kTtsFormats.contains(format) ? format : d.format,
      autoRead: json['autoRead'] as bool? ?? d.autoRead,
      skipActions: json['skipActions'] as bool? ?? d.skipActions,
      sampleText: '${json['sampleText'] ?? d.sampleText}',
    );
  }
}

/// 输出格式白名单（MediaPlayer 只认得了这几种，pcm 需要额外封装）。
const List<String> kTtsFormats = ['mp3', 'wav', 'ogg', 'm4a', 'aac'];

/// OpenAI 系的标准音色（其它服务商请自己填，这里只是常用预设）。
const List<({String id, String label})> kTtsVoicePresets = [
  (id: 'nova', label: 'nova · 女声，清亮自然'),
  (id: 'shimmer', label: 'shimmer · 女声，柔和'),
  (id: 'coral', label: 'coral · 女声，温暖'),
  (id: 'alloy', label: 'alloy · 中性，平稳'),
  (id: 'ash', label: 'ash · 男声，沉稳'),
  (id: 'onyx', label: 'onyx · 男声，低沉'),
  (id: 'echo', label: 'echo · 男声，干脆'),
  (id: 'fable', label: 'fable · 讲故事的语气'),
  (id: 'sage', label: 'sage · 女声，平静'),
  (id: 'verse', label: 'verse · 有表现力的男声'),
];

/// 常见 TTS 服务商的 Base URL（点一下填进 endpoint）。
const List<({String name, String url, String model})> kTtsEndpointPresets = [
  (name: 'OpenAI', url: 'https://api.openai.com/v1', model: 'tts-1'),
  (
    name: 'SiliconFlow',
    url: 'https://api.siliconflow.cn/v1',
    model: 'FunAudioLLM/CosyVoice2-0.5B'
  ),
  (name: 'Groq', url: 'https://api.groq.com/openai/v1', model: 'playai-tts'),
];

/// 去掉括号里的动作/心理描写，只留能读出声的台词。
///
/// 全角与半角括号都处理；嵌套括号按「先到先关」算，足够覆盖本项目的写法。
String ttsSpeakableText(String text, {bool skipActions = true}) {
  var s = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (skipActions) {
    final out = StringBuffer();
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == '(' || ch == '（') {
        depth++;
        continue;
      }
      if (ch == ')' || ch == '）') {
        if (depth > 0) {
          depth--;
          continue;
        }
        // depth == 0：没有对应的开括号，这个右括号是台词的一部分，留着。
      }
      if (depth == 0) out.write(ch);
    }
    s = out.toString();
  }
  // 朗读不需要换行；连续空白并成一个空格。
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}
