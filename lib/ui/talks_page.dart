import 'package:flutter/material.dart';

import '../models.dart';
import 'chat_page.dart';
import 'widgets.dart';

class TalksPage extends StatelessWidget {
  const TalksPage({super.key});

  static String _time(DateTime t) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    if (now.year == t.year && now.month == t.month && now.day == t.day) return '${two(t.hour)}:${two(t.minute)}';
    if (now.year == t.year) return '${t.month}/${t.day}';
    return '${t.year}/${t.month}/${t.day}';
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final sessions = state.sessionsByRecent;
    return Scaffold(
      appBar: AppBar(title: const Text('トーク')),
      body: sessions.isEmpty
          ? const Center(child: Text('まだトークがありません。\nキャラクターを選んで話しかけてみましょう。', textAlign: TextAlign.center))
          : ListView.separated(
              itemCount: sessions.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
              itemBuilder: (context, i) {
                final s = sessions[i];
                final cast = s.characterIds.map(state.characterById).toList();
                final last = s.messages.lastOrNull;
                final preview = last == null
                    ? ''
                    : '${last.role == MessageRole.user ? 'あなた: ' : (s.isGroup ? '${state.characterById(last.characterId)?.name ?? ''}: ' : '')}'
                          '${last.content.replaceAll('\n', ' ')}';
                return Dismissible(
                  key: ValueKey(s.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Theme.of(context).colorScheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete),
                  ),
                  confirmDismiss: (_) => confirm(context, 'トークを削除', '「${s.title}」を削除しますか？', ok: '削除'),
                  onDismissed: (_) => state.deleteSession(s),
                  child: ListTile(
                    leading: s.isGroup
                        ? SizedBox(
                            width: 44,
                            child: Stack(
                              children: [
                                CharacterAvatar(cast.first, radius: 16),
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: CharacterAvatar(cast.length > 1 ? cast[1] : null, radius: 16),
                                ),
                              ],
                            ),
                          )
                        : CharacterAvatar(cast.firstOrNull),
                    title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(_time(s.updatedAt), style: Theme.of(context).textTheme.labelSmall),
                        if (state.isGenerating(s))
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                      ],
                    ),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(sessionId: s.id))),
                  ),
                );
              },
            ),
    );
  }
}
