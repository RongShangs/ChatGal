import 'package:flutter/material.dart';

import '../../app/app_logger.dart';
import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import '../tts/tts_service.dart';
import '../tts/tts_settings.dart';
import 'api_settings.dart';
import 'settings_widgets.dart';

/// 语音配置（云端 TTS）。
///
/// 与对话供应商完全分开：对话是「谁说」，语音是「声音从哪来」，
/// 两者可以是不同服务商。这里的每一项都和朗读链路联动：
/// **语速** → `speed` 参数；**音色** → `voice` 参数；**输出格式** → 落盘后缀
/// （决定原生播放器能不能解）；**跳过动作描写** → 送进 TTS 的文本怎么切。
class VoiceSettingsPage extends StatefulWidget {
  const VoiceSettingsPage({
    super.key,
    required this.theme,
    required this.api,
    this.onChanged,
  });

  final ChatGalTheme theme;
  final ApiSettingsStore api;
  final VoidCallback? onChanged;

  @override
  State<VoiceSettingsPage> createState() => _VoiceSettingsPageState();
}

class _VoiceSettingsPageState extends State<VoiceSettingsPage> {
  AppSettings _settings = AppSettings.empty;
  late final TextEditingController _endpoint;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _voice;
  late final TextEditingController _sample;
  late final TtsController _tts;
  bool _obscureKey = true;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _settings = widget.api.load();
    final s = _settings.tts;
    _endpoint = TextEditingController(text: s.endpoint);
    _key = TextEditingController(text: s.apiKey);
    _model = TextEditingController(text: s.model);
    _voice = TextEditingController(text: s.voice);
    _sample = TextEditingController(text: s.sampleText);
    _speed = s.speed;
    _tts = TtsController(
      rootDir: widget.api.rootDir,
      settingsSource: widget.api,
    )..addListener(_onTtsChanged);
  }

  @override
  void dispose() {
    _tts.removeListener(_onTtsChanged);
    _tts.dispose();
    _endpoint.dispose();
    _key.dispose();
    _model.dispose();
    _voice.dispose();
    _sample.dispose();
    super.dispose();
  }

  /// 试听出错时给一次提示（不重复弹同一条）。
  String? _lastReportedError;

  void _onTtsChanged() {
    if (!mounted) return;
    final err = _tts.lastError;
    if (err != null && err != _lastReportedError) {
      _lastReportedError = err;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('朗读失败：$err')));
    }
    if (err == null) _lastReportedError = null;
    setState(() {});
  }

  Future<void> _persist(TtsSettings next) async {
    setState(() => _settings = _settings.copyWith(tts: next));
    await widget.api.update((s) => s.copyWith(tts: next));
    widget.onChanged?.call();
  }

  TtsSettings _currentForm() => _settings.tts.copyWith(
    endpoint: _endpoint.text.trim(),
    apiKey: _key.text.trim(),
    model: _model.text.trim(),
    voice: _voice.text.trim(),
    speed: _speed,
    sampleText: _sample.text.trim().isEmpty
        ? const TtsSettings().sampleText
        : _sample.text.trim(),
  );

  Future<void> _audition() async {
    await _persist(_currentForm());
    if (!mounted) return;
    _tts.clearError();
    await _tts.speak(_settings.tts.sampleText, interrupt: true);
  }

  /// 引导里的一个编号步骤（① ② ③）。
  Widget _howToStep(ChatGalTheme t, String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              number,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: t.accent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, height: 1.5, color: t.ink),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final s = _settings.tts;
    final busy =
        _tts.state == TtsState.preparing || _tts.state == TtsState.playing;

    return ChatGalShell(
      theme: t,
      title: '语音配置',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          SettingsPanel(
            theme: t,
            child: SwitchListTile(
              value: s.enabled,
              activeThumbColor: t.accent,
              title: Text('语音朗读', style: TextStyle(color: t.ink)),
              subtitle: Text(
                s.enabled ? '开着：聊天页的 AI 台词旁边会出现朗读按钮' : '关着：聊天页不显示朗读相关按钮',
                style: TextStyle(fontSize: 11.5, color: t.sub),
              ),
              onChanged: (v) {
                appLog.i('tts', '语音朗读${v ? '开启' : '关闭'}');
                _persist(s.copyWith(enabled: v));
              },
            ),
          ),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.record_voice_over_outlined,
                      size: 16,
                      color: t.accent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '怎么让它出声',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _howToStep(
                  t,
                  '1',
                  '在下面挑一个服务商（三家都提供免费额度）；想用别家就选'
                      '「自定义」再自己填地址。',
                ),
                _howToStep(
                  t,
                  '2',
                  '把服务商给你的 API Key 填进去，再挑一个音色名字。',
                ),
                _howToStep(
                  t,
                  '3',
                  '滑到最底部点「试听」——听到声音就配好了。配好之后，'
                      '聊天页每条回复下面会出现「朗读」按钮。',
                ),
                const SizedBox(height: 4),
                Text(
                  '朗读要用你的额度：那段台词会发给你选的服务商。'
                  '不想让台词外发，就把上面这个开关关掉。',
                  style: TextStyle(fontSize: 11, height: 1.45, color: t.sub),
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.md),
          SettingsSectionTitle('服务商', theme: t),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in kTtsEndpointPresets)
                ActionChip(
                  label: Text(
                    p.name,
                    style: TextStyle(
                      fontSize: 12,
                      color: _endpoint.text.trim() == p.url
                          ? Colors.white
                          : t.ink,
                    ),
                  ),
                  backgroundColor: _endpoint.text.trim() == p.url
                      ? t.accent
                      : t.accent.withValues(alpha: 0.12),
                  side: BorderSide(color: t.accent.withValues(alpha: 0.3)),
                  onPressed: () {
                    setState(() {
                      _endpoint.text = p.url;
                      _model.text = p.model;
                    });
                    _persist(_currentForm());
                  },
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              4,
            ),
            child: Column(
              children: [
                TextField(
                  controller: _endpoint,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.openai.com/v1',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _key,
                  obscureText: _obscureKey,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureKey ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: '语音模型 ID',
                    hintText: 'tts-1 / gpt-4o-mini-tts',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _voice,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '音色 ID',
                    hintText: 'nova',
                    helperText: '填服务商文档里给的音色名（各家命名完全不同）',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          const SizedBox(height: Spacing.lg),
          SettingsSectionTitle('语速与格式', theme: t),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '语速 · ${_speed.toStringAsFixed(2)}x',
                        style: TextStyle(fontSize: 12.5, color: t.ink),
                      ),
                    ),
                    Text(
                      _speed < 1.0 ? '偏慢' : (_speed > 1.0 ? '偏快' : '原速'),
                      style: TextStyle(fontSize: 11, color: t.sub),
                    ),
                  ],
                ),
                Slider(
                  value: _speed.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  divisions: 30,
                  activeColor: t.accent,
                  label: '${_speed.toStringAsFixed(2)}x',
                  onChanged: (v) => setState(() => _speed = v),
                  onChangeEnd: (v) {
                    appLog.i('tts', '语速设为 ${v.toStringAsFixed(2)}x');
                    _persist(_currentForm().copyWith(speed: v));
                  },
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: kTtsFormats.contains(s.format)
                      ? s.format
                      : 'mp3',
                  decoration: const InputDecoration(
                    labelText: '输出格式',
                    helperText: '不确定就别改：mp3 各家都支持',
                    helperMaxLines: 2,
                  ),
                  items: [
                    for (final f in kTtsFormats)
                      DropdownMenuItem(value: f, child: Text(f)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _persist(s.copyWith(format: v));
                  },
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
          SettingsSectionTitle('朗读行为', theme: t),
          SettingsPanel(
            theme: t,
            child: Column(
              children: [
                SwitchListTile(
                  value: s.autoRead,
                  activeThumbColor: t.accent,
                  title: Text('自动朗读新回复', style: TextStyle(color: t.ink)),
                  subtitle: Text(
                    'AI 回复一到达就自动读出来（一条回复会被拆成多段依次读）',
                    style: TextStyle(fontSize: 11.5, color: t.sub),
                  ),
                  onChanged: (v) => _persist(s.copyWith(autoRead: v)),
                ),
                SwitchListTile(
                  value: s.skipActions,
                  activeThumbColor: t.accent,
                  title: Text('跳过括号里的动作与心理描写', style: TextStyle(color: t.ink)),
                  subtitle: Text(
                    '只读台词，不读「（轻轻点头）」这类描写',
                    style: TextStyle(fontSize: 11.5, color: t.sub),
                  ),
                  onChanged: (v) => _persist(s.copyWith(skipActions: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.sm),
          SettingsSectionTitle('试听', theme: t),
          SettingsPanel(
            theme: t,
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              Spacing.md,
            ),
            child: Column(
              children: [
                TextField(
                  controller: _sample,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: '试听文本',
                    helperText: '点「试听」会先把上面的设置存下来，再合成这句话',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: t.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        onPressed: busy ? null : _audition,
                        icon: busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.play_arrow_rounded, size: 18),
                        label: Text(switch (_tts.state) {
                          TtsState.preparing => '合成中…',
                          TtsState.playing => '朗读中…',
                          _ => '试听',
                        }),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          side: BorderSide(color: t.sub.withValues(alpha: 0.4)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        onPressed: busy ? () => _tts.stop() : null,
                        icon: const Icon(Icons.stop_rounded, size: 18),
                        label: const Text('停止'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '设置不完整时不会发起请求（需要 Base URL、模型 ID、音色 ID）。'
                    '合成结果会缓存，同一句再听一次不会再请求一次。',
                    style: TextStyle(fontSize: 11, height: 1.5, color: t.sub),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
