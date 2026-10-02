import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import 'character_editor.dart';
import 'chat_page.dart';
import 'connect_page.dart';
import 'widgets.dart';

class CharactersPage extends StatefulWidget {
  const CharactersPage({super.key});

  @override
  State<CharactersPage> createState() => _CharactersPageState();
}

enum _Sort { recent, name, favorite }

class _CharactersPageState extends State<CharactersPage> {
  final _search = TextEditingController();
  String? _tag;
  _Sort _sort = _Sort.recent;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Character> _filtered(List<Character> all) {
    final q = _search.text.trim().toLowerCase();
    final list = all.where((c) {
      if (_tag != null && !c.tags.contains(_tag)) return false;
      if (_sort == _Sort.favorite && !c.favorite) return false;
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.tagline.toLowerCase().contains(q) ||
          c.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
    switch (_sort) {
      case _Sort.name:
        list.sort((a, b) => a.name.compareTo(b.name));
      case _Sort.recent:
      case _Sort.favorite:
        list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final characters = _filtered(state.characters);
    final tags = state.allTags.take(20).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('キャラクター'),
        actions: [
          ConnectionChip(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectPage()))),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'import' => _importFromClipboard(),
              'group' => _startGroupChat(),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'group',
                child: ListTile(leading: Icon(Icons.groups), title: Text('グループトークを作る')),
              ),
              PopupMenuItem(
                value: 'import',
                child: ListTile(leading: Icon(Icons.content_paste), title: Text('クリップボードから読み込む')),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CharacterEditorPage())),
        icon: const Icon(Icons.add),
        label: const Text('キャラを作る'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SearchBar(
              controller: _search,
              hintText: '名前・タグで検索',
              leading: const Icon(Icons.search),
              onChanged: (_) => setState(() {}),
              trailing: [
                if (_search.text.isNotEmpty)
                  IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_search.clear)),
              ],
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final s in _Sort.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(switch (s) {
                        _Sort.recent => '新しい順',
                        _Sort.name => '名前順',
                        _Sort.favorite => '★ お気に入り',
                      }),
                      selected: _sort == s,
                      onSelected: (_) => setState(() => _sort = s),
                    ),
                  ),
                const VerticalDivider(indent: 12, endIndent: 12),
                for (final t in tags)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FilterChip(
                      label: Text('#$t'),
                      selected: _tag == t,
                      onSelected: (on) => setState(() => _tag = on ? t : null),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: characters.isEmpty
                ? const Center(child: Text('キャラクターがいません'))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = (constraints.maxWidth / 420).floor().clamp(1, 4);
                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisExtent: 112,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: characters.length,
                        itemBuilder: (context, i) => _CharacterCard(characters[i]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    try {
      final c = AppScope.read(context).importCharacter(data?.text ?? '');
      showInfo(context, '「${c.name}」を読み込みました');
    } catch (e) {
      showError(context, '読み込めませんでした: $e');
    }
  }

  Future<void> _startGroupChat() async {
    final state = AppScope.read(context);
    final selected = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('グループトーク'),
          content: SizedBox(
            width: 400,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text('参加させるキャラクターを 2 人以上選んでください'),
                for (final c in state.characters)
                  CheckboxListTile(
                    value: selected.contains(c.id),
                    secondary: CharacterAvatar(c, radius: 16),
                    title: Text(c.name),
                    onChanged: (v) => setDialogState(() => v! ? selected.add(c.id) : selected.remove(c.id)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
            FilledButton(
              onPressed: selected.length >= 2 ? () => Navigator.pop(context, true) : null,
              child: const Text('はじめる'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final cast = state.characters.where((c) => selected.contains(c.id)).toList();
    final session = state.newSession(cast);
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(sessionId: session.id)));
  }
}

class _CharacterCard extends StatelessWidget {
  const _CharacterCard(this.character);

  final Character character;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showCharacterSheet(context, character),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CharacterAvatar(character, radius: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            character.name,
                            style: theme.textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (character.favorite) const Icon(Icons.star, size: 16, color: Colors.amber),
                      ],
                    ),
                    if (character.tagline.isNotEmpty)
                      Text(
                        character.tagline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      character.tags.map((t) => '#$t').join(' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showCharacterSheet(BuildContext context, Character character) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final state = AppScope.of(sheetContext);
      final latest = state.latestSessionFor(character);
      void openChat(String sessionId) {
        Navigator.pop(sheetContext);
        Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(sessionId: sessionId)));
      }

      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Row(
              children: [
                CharacterAvatar(character, radius: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(character.name, style: Theme.of(context).textTheme.headlineSmall),
                      if (character.tagline.isNotEmpty) Text(character.tagline),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'お気に入り',
                  icon: Icon(character.favorite ? Icons.star : Icons.star_border, color: Colors.amber),
                  onPressed: () {
                    character.favorite = !character.favorite;
                    state.commit();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              children: [
                for (final t in character.tags) Chip(label: Text('#$t'), visualDensity: VisualDensity.compact),
              ],
            ),
            if (character.description.isNotEmpty) ...[const SizedBox(height: 12), Text(character.description)],
            const SizedBox(height: 20),
            if (latest != null)
              FilledButton.icon(
                onPressed: () => openChat(latest.id),
                icon: const Icon(Icons.chat),
                label: Text('続きから話す (${latest.messages.length} 件)'),
              ),
            const SizedBox(height: 8),
            (latest == null ? FilledButton.icon : OutlinedButton.icon)(
              onPressed: () => openChat(state.newSession([character]).id),
              icon: const Icon(Icons.add_comment),
              label: const Text('新しいトークを始める'),
            ),
            const SizedBox(height: 16),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('編集'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.push(context, MaterialPageRoute(builder: (_) => CharacterEditorPage(original: character)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_all),
              title: const Text('複製'),
              onTap: () {
                final copy = Character.fromJson({...character.toShareJson(), 'name': '${character.name} のコピー'});
                state.upsertCharacter(copy);
                Navigator.pop(sheetContext);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('共有用にコピー (JSON)'),
              subtitle: const Text('別の端末で「クリップボードから読み込む」で取り込めます'),
              onTap: () async {
                await Clipboard.setData(
                  ClipboardData(text: const JsonEncoder.withIndent('  ').convert(character.toShareJson())),
                );
                if (sheetContext.mounted) showInfo(sheetContext, 'クリップボードにコピーしました');
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: const Text('削除'),
              onTap: () async {
                final ok = await confirm(sheetContext, '削除', '「${character.name}」と、このキャラとのトークを削除しますか？', ok: '削除');
                if (!ok || !sheetContext.mounted) return;
                state.deleteCharacter(character);
                Navigator.pop(sheetContext);
              },
            ),
          ],
        ),
      );
    },
  );
}
