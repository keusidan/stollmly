import 'package:flutter/material.dart';

import '../models.dart';
import 'widgets.dart';

const _palette = [
  0xFF7C4DFF, 0xFFE91E63, 0xFFF44336, 0xFFFF9800, 0xFFFFC107, 0xFF4CAF50, //
  0xFF009688, 0xFF03A9F4, 0xFF3F51B5, 0xFF795548, 0xFF455A64, 0xFF9E9E9E,
];

/// キャラクター作成・編集。[original] が null なら新規作成。
class CharacterEditorPage extends StatefulWidget {
  const CharacterEditorPage({super.key, this.original});

  final Character? original;

  @override
  State<CharacterEditorPage> createState() => _CharacterEditorPageState();
}

class _CharacterEditorPageState extends State<CharacterEditorPage> {
  late final Character _draft = widget.original?.copy() ?? Character();
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: _draft.name);
  late final _avatar = TextEditingController(text: _draft.avatar);
  late final _tagline = TextEditingController(text: _draft.tagline);
  late final _description = TextEditingController(text: _draft.description);
  late final _prompt = TextEditingController(text: _draft.prompt);
  late final _intro = TextEditingController(text: _draft.intro);
  late final _example = TextEditingController(text: _draft.exampleDialogue);
  late final _tags = TextEditingController(text: _draft.tags.join(' '));

  @override
  void dispose() {
    for (final c in [_name, _avatar, _tagline, _description, _prompt, _intro, _example, _tags]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    _draft
      ..name = _name.text.trim()
      ..avatar = _avatar.text.trim()
      ..tagline = _tagline.text.trim()
      ..description = _description.text.trim()
      ..prompt = _prompt.text.trim()
      ..intro = _intro.text.trim()
      ..exampleDialogue = _example.text.trim()
      ..tags = _tags.text.split(RegExp(r'[\s,、#]+')).map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList();
    AppScope.read(context).upsertCharacter(_draft);
    Navigator.pop(context);
  }

  Widget _section(String title, [String? help]) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (help != null)
          Text(help, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
      ],
    ),
  );

  Widget _segmented<T extends Enum>(
    String label,
    List<T> values,
    T current,
    String Function(T) labelOf,
    ValueChanged<T> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(label)),
          Expanded(
            child: SegmentedButton<T>(
              segments: [for (final v in values) ButtonSegment(value: v, label: Text(labelOf(v)))],
              selected: {current},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => onChanged(s.first)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.original == null ? 'キャラを作る' : 'キャラを編集'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('保存')),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
              children: [
                _section('プロフィール', '一覧に表示される情報です。紹介文は AI には渡りません。'),
                Row(
                  children: [
                    ListenableBuilder(
                      listenable: Listenable.merge([_avatar, _name]),
                      builder: (_, _) => CharacterAvatar(
                        Character(name: _name.text, avatar: _avatar.text, colorValue: _draft.colorValue),
                        radius: 32,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextFormField(
                        controller: _avatar,
                        decoration: const InputDecoration(labelText: 'アイコン (絵文字 1 文字など)', border: OutlineInputBorder()),
                        maxLength: 4,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final color in _palette)
                      InkWell(
                        onTap: () => setState(() => _draft.colorValue = color),
                        customBorder: const CircleBorder(),
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor: Color(color),
                          child: _draft.colorValue == color
                              ? const Icon(Icons.check, size: 16, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: '名前 *', border: OutlineInputBorder()),
                  validator: (v) => (v == null || v.trim().isEmpty) ? '名前を入力してください' : null,
                  maxLength: 40,
                ),
                TextFormField(
                  controller: _tagline,
                  decoration: const InputDecoration(labelText: 'ひとこと (肩書き)', border: OutlineInputBorder()),
                  maxLength: 60,
                ),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: '紹介文 (ユーザー向け)', border: OutlineInputBorder()),
                  minLines: 2,
                  maxLines: 6,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _tags,
                  decoration: const InputDecoration(
                    labelText: 'タグ (スペース区切り)',
                    hintText: '例: 幼なじみ 学園 ツンデレ',
                    border: OutlineInputBorder(),
                  ),
                ),
                _section(
                  'キャラクター設定 (プロンプト)',
                  'AI に渡る設定です。名前・年齢・一人称/二人称・性格・口調・関係性などを書きます。'
                      '{{char}} はキャラ名、{{user}} はユーザー名に置き換わります。',
                ),
                TextFormField(
                  controller: _prompt,
                  decoration: const InputDecoration(border: OutlineInputBorder(), alignLabelWithHint: true),
                  minLines: 8,
                  maxLines: 24,
                  maxLength: 8000,
                ),
                _section('イントロ', 'トーク開始時に最初に表示される場面です。場所・関係・直前の出来事を書くと物語に入りやすくなります。'),
                TextFormField(
                  controller: _intro,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '*放課後の教室。窓から夕日が差し込んでいる。*\nあ、やっと来た！',
                  ),
                  minLines: 4,
                  maxLines: 12,
                  maxLength: 3000,
                ),
                _section('口調の例', '「{{user}}: …」「{{char}}: …」の形式で、話し方のお手本を書きます。'),
                TextFormField(
                  controller: _example,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                  minLines: 3,
                  maxLines: 10,
                  maxLength: 3000,
                ),
                _section('物語の進め方'),
                _segmented('視点', NarrationPov.values, _draft.pov, (v) => v.label, (v) => _draft.pov = v),
                _segmented('テンポ', StoryTempo.values, _draft.tempo, (v) => v.label, (v) => _draft.tempo = v),
                _segmented('距離感', Openness.values, _draft.openness, (v) => v.label, (v) => _draft.openness = v),
                _segmented('長さ', ReplyLength.values, _draft.replyLength, (v) => v.label, (v) => _draft.replyLength = v),
                _section('ロアブロック', 'キーワードが会話に出てきたときだけ AI に渡る設定です。世界観・地名・人物などをまとめておけます。'),
                for (final entry in _draft.lore)
                  Card(
                    child: ListTile(
                      title: Text(entry.title.isEmpty ? '(無題)' : entry.title),
                      subtitle: Text(
                        entry.alwaysOn ? '常に有効' : 'キーワード: ${entry.keywords.join(', ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => _draft.lore = [..._draft.lore]..remove(entry)),
                      ),
                      onTap: () => _editLore(entry),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _editLore(null),
                  icon: const Icon(Icons.add),
                  label: const Text('ロアブロックを追加'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editLore(LoreEntry? original) async {
    final entry = original ?? LoreEntry();
    final title = TextEditingController(text: entry.title);
    final keywords = TextEditingController(text: entry.keywords.join(', '));
    final content = TextEditingController(text: entry.content);
    var alwaysOn = entry.alwaysOn;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('ロアブロック'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    decoration: const InputDecoration(labelText: 'タイトル'),
                  ),
                  TextField(
                    controller: keywords,
                    decoration: const InputDecoration(labelText: 'キーワード (カンマ区切り)', hintText: '砦, 灰狼'),
                    enabled: !alwaysOn,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('常に有効にする'),
                    value: alwaysOn,
                    onChanged: (v) => setDialogState(() => alwaysOn = v),
                  ),
                  TextField(
                    controller: content,
                    decoration: const InputDecoration(labelText: '内容', border: OutlineInputBorder()),
                    minLines: 4,
                    maxLines: 12,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK')),
          ],
        ),
      ),
    );
    if (ok == true) {
      setState(() {
        entry
          ..title = title.text.trim()
          ..keywords = keywords.text.split(RegExp(r'[,、]')).map((k) => k.trim()).where((k) => k.isNotEmpty).toList()
          ..content = content.text.trim()
          ..alwaysOn = alwaysOn;
        if (original == null) _draft.lore = [..._draft.lore, entry];
      });
    }
    title.dispose();
    keywords.dispose();
    content.dispose();
  }
}
