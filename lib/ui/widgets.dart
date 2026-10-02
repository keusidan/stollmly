import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';

/// どこからでも AppState を引けるようにする。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// 再描画を購読せずに参照だけしたいとき (コールバック内など)。
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class CharacterAvatar extends StatelessWidget {
  const CharacterAvatar(this.character, {super.key, this.radius = 22});

  final Character? character;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = character;
    final color = Color(c?.colorValue ?? 0xFF9E9E9E);
    final label = (c == null)
        ? '?'
        : c.avatar.trim().isNotEmpty
        ? c.avatar.trim()
        : (c.name.trim().isNotEmpty ? c.name.trim().characters.first : '?');
    return CircleAvatar(
      radius: radius,
      backgroundColor: color.withValues(alpha: 0.18),
      child: Text(
        label,
        style: TextStyle(fontSize: radius * 0.9, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// `*描写*` を斜体・淡色で、台詞を通常色で表示する (アスタリスク記法)。
class RoleplayText extends StatelessWidget {
  const RoleplayText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  static final _pattern = RegExp(r'\*([^*]+)\*');

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final narration = base.copyWith(
      fontStyle: FontStyle.italic,
      color: (base.color ?? Theme.of(context).colorScheme.onSurface).withValues(alpha: 0.62),
    );
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _pattern.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(text: m.group(1), style: narration));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    // SelectableText だと長押しメニューと競合するので Text.rich (コピーはメニューから)
    return Text.rich(TextSpan(style: base, children: spans));
  }
}

class ConnectionChip extends StatelessWidget {
  const ConnectionChip({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (state.connection) {
      ConnectionStatus.connected => (Icons.link, Colors.green, state.activeHost?.name ?? '接続中'),
      ConnectionStatus.connecting => (Icons.sync, scheme.primary, '接続中…'),
      ConnectionStatus.error => (Icons.link_off, scheme.error, '未接続'),
      ConnectionStatus.disconnected => (Icons.link_off, scheme.outline, '未接続'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ActionChip(
        avatar: Icon(icon, size: 18, color: color),
        label: Text(label, overflow: TextOverflow.ellipsis),
        onPressed: onTap,
      ),
    );
  }
}

Future<bool> confirm(BuildContext context, String title, String message, {String ok = 'OK'}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(ok)),
      ],
    ),
  );
  return result ?? false;
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(error.toString()), behavior: SnackBarBehavior.floating));
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
}
