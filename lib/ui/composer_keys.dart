import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 入力欄でのキー操作の扱い。
enum ComposerKeyAction {
  /// 送信する
  send,

  /// カーソル位置に改行を入れる
  newline,

  /// 何もせずに握りつぶす (Enter の押しっぱなしで改行が入らないように)
  consume,

  /// 通常どおり入力欄に任せる
  ignore,
}

/// Enter で送信、Shift+Enter で改行。ハードウェアキーボード (PC・エミュレーター) からの入力に効く。
/// スマホの画面キーボードの改行キーはキーイベントにならないので、従来どおり改行になる。
ComposerKeyAction composerKeyAction({
  required KeyEvent event,
  required bool shiftPressed,
  required TextEditingValue value,
}) {
  final key = event.logicalKey;
  if (key != LogicalKeyboardKey.enter && key != LogicalKeyboardKey.numpadEnter) return ComposerKeyAction.ignore;
  if (event is KeyUpEvent) return ComposerKeyAction.ignore;
  // IME の変換中の Enter は変換の確定に使うので触らない
  if (value.composing.isValid && !value.composing.isCollapsed) return ComposerKeyAction.ignore;
  if (shiftPressed) return ComposerKeyAction.newline;
  return event is KeyDownEvent ? ComposerKeyAction.send : ComposerKeyAction.consume;
}

/// [composerKeyAction] に従って動く FocusNode を作る。入力欄の focusNode に渡す。
FocusNode composerFocusNode({required TextEditingController controller, required VoidCallback onSend}) {
  return FocusNode(
    onKeyEvent: (node, event) {
      final action = composerKeyAction(
        event: event,
        shiftPressed: HardwareKeyboard.instance.isShiftPressed,
        value: controller.value,
      );
      switch (action) {
        case ComposerKeyAction.ignore:
          return KeyEventResult.ignored;
        case ComposerKeyAction.consume:
          return KeyEventResult.handled;
        case ComposerKeyAction.send:
          onSend();
          return KeyEventResult.handled;
        case ComposerKeyAction.newline:
          final value = controller.value;
          final selection = value.selection.isValid
              ? value.selection
              : TextSelection.collapsed(offset: value.text.length);
          controller.value = TextEditingValue(
            text: value.text.replaceRange(selection.start, selection.end, '\n'),
            selection: TextSelection.collapsed(offset: selection.start + 1),
          );
          return KeyEventResult.handled;
      }
    },
  );
}
