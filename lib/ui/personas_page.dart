import 'package:flutter/material.dart';

import '../models.dart';
import 'widgets.dart';

/// トークプロフィール (ユーザー側のペルソナ) の管理。複数作ってトークごとに切り替えられる。
class PersonasPage extends StatelessWidget {
  const PersonasPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('トークプロフィール')),
      floatingActionButton: FloatingActionButton(onPressed: () => _edit(context, null), child: const Icon(Icons.add)),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('キャラクターから見た「あなた」の設定です。名前・年齢・性格・キャラとの関係などを書くと、AI がそれに合わせて接してくれます。'),
          ),
          for (final p in state.personas)
            ListTile(
              leading: Icon(state.settings.defaultPersonaId == p.id ? Icons.star : Icons.person_outline),
              title: Text(p.name.isEmpty ? '(名前なし)' : p.name),
              subtitle: Text(
                p.description.isEmpty ? '(説明なし)' : p.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _edit(context, p),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'default') {
                    state.settings.defaultPersonaId = p.id;
                    state.commit();
                  } else if (v == 'delete' && await confirm(context, '削除', '「${p.name}」を削除しますか？', ok: '削除')) {
                    state.deletePersona(p);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'default', child: Text('既定にする')),
                  PopupMenuItem(value: 'delete', child: Text('削除')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, Persona? original) async {
    final persona = original ?? Persona();
    final name = TextEditingController(text: persona.name);
    final description = TextEditingController(text: persona.description);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(original == null ? 'プロフィールを作成' : 'プロフィールを編集'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '名前 (キャラからの呼ばれ方)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: description,
                minLines: 4,
                maxLines: 10,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: '設定',
                  hintText: '例: 17 歳の高校 2 年生。ミオの幼なじみ。少し鈍感。',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      persona
        ..name = name.text.trim()
        ..description = description.text.trim();
      final state = AppScope.read(context);
      state.settings.defaultPersonaId ??= persona.id;
      state.upsertPersona(persona);
    }
    name.dispose();
    description.dispose();
  }
}
