import 'dart:convert';
import 'package:gal_ai/gal_ai.dart';
import 'package:test/test.dart';

void main() {
  test('accepted beats retain original spaces and newlines', () {
    const original = 'I love you.\n  Really.';
    final plan = parseLookPlan(
            jsonEncode({
              'beats': [
                {'text': 'Iloveyou.'},
                {'text': 'Really.'}
              ]
            }),
            original: original)
        .plan!;
    expect(plan.reconstructs, isTrue);
    expect(plan.usableBeats.map((b) => b.text).join(), original);
  });
  test('matching after whitespace must not reuse overlapping original text',
      () {
    final plan = parseLookPlan(
            jsonEncode({
              'beats': [
                {'text': 'ab'},
                {'text': 'b'}
              ]
            }),
            original: 'a    b')
        .plan!;
    expect(plan.reconstructs, isFalse);
  });
}
