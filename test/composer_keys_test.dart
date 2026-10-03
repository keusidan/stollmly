import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stollmly/ui/composer_keys.dart';

KeyDownEvent _down(LogicalKeyboardKey key) =>
    KeyDownEvent(physicalKey: PhysicalKeyboardKey.enter, logicalKey: key, timeStamp: Duration.zero);

void main() {
  group('composerKeyAction', () {
    const plain = TextEditingValue(text: 'こんにちは', selection: TextSelection.collapsed(offset: 5));

    test('Enter は送信、Shift+Enter は改行', () {
      expect(
        composerKeyAction(event: _down(LogicalKeyboardKey.enter), shiftPressed: false, value: plain),
        ComposerKeyAction.send,
      );
      expect(
        composerKeyAction(event: _down(LogicalKeyboardKey.numpadEnter), shiftPressed: false, value: plain),
        ComposerKeyAction.send,
      );
      expect(
        composerKeyAction(event: _down(LogicalKeyboardKey.enter), shiftPressed: true, value: plain),
        ComposerKeyAction.newline,
      );
    });

    test('IME の変換中は Enter を変換の確定に任せる', () {
      const composing = TextEditingValue(
        text: 'こんにちは',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      );
      expect(
        composerKeyAction(event: _down(LogicalKeyboardKey.enter), shiftPressed: false, value: composing),
        ComposerKeyAction.ignore,
      );
    });

    test('押しっぱなしの Enter は握りつぶし、ほかのキーと KeyUp は触らない', () {
      final repeat = KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.enter,
        logicalKey: LogicalKeyboardKey.enter,
        timeStamp: Duration.zero,
      );
      expect(composerKeyAction(event: repeat, shiftPressed: false, value: plain), ComposerKeyAction.consume);
      expect(
        composerKeyAction(event: _down(LogicalKeyboardKey.keyA), shiftPressed: false, value: plain),
        ComposerKeyAction.ignore,
      );
      final up = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.enter,
        logicalKey: LogicalKeyboardKey.enter,
        timeStamp: Duration.zero,
      );
      expect(composerKeyAction(event: up, shiftPressed: false, value: plain), ComposerKeyAction.ignore);
    });
  });

  testWidgets('入力欄で Enter は送信、Shift+Enter はカーソル位置に改行', (tester) async {
    final controller = TextEditingController();
    var sent = 0;
    final focus = composerFocusNode(controller: controller, onSend: () => sent++);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(controller: controller, focusNode: focus, maxLines: 6),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'こんにちは');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.text, 'こんにちは\n');
    expect(sent, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, 1);
    expect(controller.text, 'こんにちは\n'); // Enter では改行が入らない

    focus.dispose();
    controller.dispose();
  });
}
