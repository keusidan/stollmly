import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stollmly/ui/widgets.dart';

/// 描画された (文字列, 地の文か) の組を返す。
Future<List<(String, bool)>> render(WidgetTester tester, String text) async {
  await tester.pumpWidget(MaterialApp(home: RoleplayText(text)));
  final rich = tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan;
  return [for (final span in rich.children!.cast<TextSpan>()) (span.text!, span.style?.fontStyle == FontStyle.italic)];
}

void main() {
  testWidgets('*描写* を地の文、それ以外を台詞として描画する', (tester) async {
    expect(await render(tester, '*目をそらす。*\nべつに。'), [('目をそらす。', true), ('\nべつに。', false)]);
  });

  testWidgets('閉じ忘れた * は行末までを地の文とし、以降の行はずれない (小型モデルの実際の出力)', (tester) async {
    expect(await render(tester, '*この瞬間、近づいてくる。\n*ミオは頰を動かす。*\n\nでは、行こう。\n*ミオは頰を停める。*'), [
      ('この瞬間、近づいてくる。', true),
      ('\n', false),
      ('ミオは頰を動かす。', true),
      ('\n\nでは、行こう。\n', false),
      ('ミオは頰を停める。', true),
    ]);
  });

  testWidgets('生成途中で閉じていない * は表示しない', (tester) async {
    expect(await render(tester, 'うん。\n*ミオは頰を'), [('うん。\n', false), ('ミオは頰を', true)]);
  });
}
