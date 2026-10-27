import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:chatgal/features/settings/font_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store extends ApiSettingsStore {
  _Store() : super('unused');
  AppSettings current = AppSettings.empty;
  @override
  AppSettings load() => current;
  @override
  Future<void> save(AppSettings value) async {
    current = value;
  }

  @override
  Future<AppSettings> update(AppSettings Function(AppSettings) change) async {
    return current = change(current);
  }
}

void main() {
  testWidgets('字体页持有旧快照时保存字号，不覆盖随后更新的主题', (tester) async {
    final store = _Store();
    await tester.pumpWidget(
      MaterialApp(
        home: FontSettingsPage(theme: ChatGalTheme.violet, api: store),
      ),
    );
    await store.update((s) => s.copyWith(themeId: 'night'));
    tester.widget<Slider>(find.byType(Slider).first).onChangeEnd!(22);
    await tester.pump();
    expect(store.current.chatFontSize, 22);
    expect(store.current.themeId, 'night');
  });
}
