import 'package:chatgal/features/tts/tts_service.dart';
import 'package:chatgal/features/tts/tts_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TtsSettings', () {
    test('默认值：关闭、不完整配置、语速原速', () {
      const s = TtsSettings();
      expect(s.enabled, isFalse);
      expect(s.configured, isFalse);
      expect(s.speed, 1.0);
      expect(s.format, 'mp3');
      expect(s.skipActions, isTrue);
      expect(s.autoRead, isFalse);
    });

    test('enabled 但缺模型/音色时仍算未配置', () {
      const s = TtsSettings(enabled: true, model: '', voice: 'nova');
      expect(s.configured, isFalse);
      const ok = TtsSettings(enabled: true);
      expect(ok.configured, isTrue);
    });

    test('speechUrl 去掉末尾斜杠', () {
      const a = TtsSettings(endpoint: 'https://api.example.com/v1');
      const b = TtsSettings(endpoint: 'https://api.example.com/v1/');
      expect(a.speechUrl(), 'https://api.example.com/v1/audio/speech');
      expect(b.speechUrl(), a.speechUrl());
    });

    test('requestBody 就是 OpenAI 兼容那四个字段 + 音色', () {
      const s = TtsSettings(
        enabled: true,
        model: 'tts-1',
        voice: 'nova',
        speed: 1.25,
        format: 'wav',
      );
      final body = s.requestBody('你好');
      expect(body['model'], 'tts-1');
      expect(body['input'], '你好');
      expect(body['voice'], 'nova');
      expect(body['speed'], 1.25);
      expect(body['response_format'], 'wav');
    });

    test('fromJson 夹住越界语速、挡住非法格式', () {
      final s = TtsSettings.fromJson({
        'enabled': true,
        'speed': 99.0,
        'format': 'exe',
        'voice': 'coral',
      });
      expect(s.speed, 4.0);
      expect(s.format, 'mp3');
      expect(s.voice, 'coral');
    });

    test('toJson / fromJson 往返一致', () {
      const s = TtsSettings(
        enabled: true,
        endpoint: 'http://127.0.0.1:8080/v1',
        apiKey: 'k',
        model: 'tts-1',
        voice: 'alloy',
        speed: 0.75,
        format: 'ogg',
        autoRead: true,
        skipActions: false,
        sampleText: '试听',
      );
      final back = TtsSettings.fromJson(s.toJson());
      expect(back.toJson(), s.toJson());
    });

    test('copyWith 只改点名的那一项', () {
      const s = TtsSettings(voice: 'nova', speed: 1.0);
      final t = s.copyWith(speed: 1.5);
      expect(t.voice, 'nova');
      expect(t.speed, 1.5);
      expect(t.endpoint, s.endpoint);
    });
  });

  group('ttsSpeakableText', () {
    test('默认跳过括号里的动作与心理描写', () {
      expect(
        ttsSpeakableText('（轻轻点头）你回来了。'),
        '你回来了。',
      );
      expect(
        ttsSpeakableText('(sigh) 我等你很久了。'),
        '我等你很久了。',
      );
    });

    test('skipActions=false 时原样保留', () {
      expect(
        ttsSpeakableText('（轻轻点头）你回来了。', skipActions: false),
        '（轻轻点头）你回来了。',
      );
    });

    test('嵌套括号也只留括号外的内容', () {
      expect(ttsSpeakableText('（转过头（小声））嗯。'), '嗯。');
    });

    test('换行与多余空白压成单个空格', () {
      expect(ttsSpeakableText('今天……\n\n你回来得好早。'), '今天…… 你回来得好早。');
    });

    test('只有动作描写时结果为空（调用方据此提示）', () {
      expect(ttsSpeakableText('（沉默地站着）'), '');
    });

    test('半角右括号不吞掉后面的台词', () {
      expect(ttsSpeakableText('（笑）好）呀'), '好）呀');
    });
  });

  group('TtsController 缓存键', () {
    test('stableKey 稳定且不同输入不同键', () {
      expect(TtsController.stableKey('abc'), TtsController.stableKey('abc'));
      expect(
        TtsController.stableKey('abc'),
        isNot(TtsController.stableKey('abd')),
      );
      expect(TtsController.stableKey('你好'), hasLength(8));
    });
  });
}
