import 'package:flutter/material.dart';

import '../app_state.dart';
import '../memory/memory_logic.dart';
import '../memory/memory_models.dart';
import '../models.dart';
import 'widgets.dart';

/// トークの長期記憶 (重要メモ・あらすじ) を見る・直す画面。
class MemoryPage extends StatelessWidget {
  const MemoryPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final s = state.sessions.where((x) => x.id == sessionId).firstOrNull;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('このトークは削除されました')),
      );
    }
    final mem = s.memory;
    final cfg = state.settings.memoryConfig;
    final theme = Theme.of(context);
    final busy = state.isMemoryBusy(s);

    Widget header(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          ),
          ?trailing,
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('記憶'),
        actions: [
          IconButton(
            tooltip: '今すぐ更新',
            icon: const Icon(Icons.sync),
            onPressed: busy ? null : () => state.scheduleMemory(s, delay: Duration.zero),
          ),
          IconButton(
            tooltip: '今すぐ再生成',
            icon: const Icon(Icons.auto_fix_high),
            onPressed: busy ? null : () => _rebuild(context, state, s),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (!cfg.enabled)
            const ListTile(leading: Icon(Icons.info_outline), title: Text('長期記憶はオフになっています (設定 → 長期記憶)')),
          ListTile(
            leading: const Icon(Icons.timeline),
            title: Text('要約済み: ${mem.coveredCount} / ${s.messages.length} 件の発言'),
            subtitle: Text(
              '${cfg.interval} 往復ごとに自動でまとめます。'
              '${_nextHint(mem.coveredCount, s.messages.length, cfg.chunkMessages)}'
              '${busy ? '\nいま整理しています…' : ''}'
              '${mem.lastError != null ? '\n前回のエラー: ${mem.lastError}' : ''}',
            ),
          ),
          ListTile(
            leading: Icon(
              state.memory.retrievalAvailable ? Icons.manage_search : Icons.search_off,
              color: state.memory.retrievalAvailable ? null : theme.colorScheme.outline,
            ),
            title: Text(
              !cfg.retrievalEnabled
                  ? '過去の発言の検索: オフ'
                  : state.memory.retrievalAvailable
                  ? '過去の発言の検索: 有効 (${cfg.embedModel})'
                  : '過去の発言の検索: 一時停止中',
            ),
            subtitle: state.memory.retrievalUnavailableReason == null
                ? null
                : Text(
                    '${state.memory.retrievalUnavailableReason}\n'
                    'ホストで `ollama pull ${cfg.embedModel}` すると使えるようになります。重要メモとあらすじは使えます。',
                  ),
          ),
          header(
            '重要メモ (${totalChars(mem.facts)} / ${cfg.factsMaxChars} 字)',
            trailing: TextButton.icon(
              onPressed: () => _editFact(context, state, s, null),
              icon: const Icon(Icons.add),
              label: const Text('追加'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('毎回 AI に渡す「忘れたら困る事実」です。📌 ピン留めした項目は自動整理で消えません。'),
          ),
          if (mem.facts.isEmpty)
            const ListTile(title: Text('(まだありません)'))
          else
            for (final f in mem.facts) _FactTile(session: s, item: f),
          header(
            'あらすじ',
            trailing: TextButton.icon(
              onPressed: () => _editSynopsis(context, state, s),
              icon: const Icon(Icons.edit),
              label: const Text('編集'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(mem.synopsis.trim().isEmpty ? '(まだありません)' : mem.synopsis.trim()),
              ),
            ),
          ),
          if (mem.chunks.isNotEmpty)
            ExpansionTile(
              title: Text('区切りごとの要約 (${mem.chunks.length})'),
              children: [
                for (final c in mem.chunks.reversed)
                  ListTile(dense: true, title: Text('発言 ${c.start + 1}〜${c.end}'), subtitle: Text(c.summary)),
              ],
            ),
        ],
      ),
    );
  }

  static String _nextHint(int covered, int total, int chunkMessages) {
    final turns = turnsUntilNextChunk(covered: covered, total: total, chunkMessages: chunkMessages);
    return turns == 0 ? '(次の整理を待っています)' : '(次の整理まであと $turns 往復)';
  }

  Future<void> _rebuild(BuildContext context, AppState state, ChatSession s) async {
    final ok = await confirm(context, '今すぐ再生成', 'ピン留め以外の重要メモ・あらすじを捨てて、今の会話履歴から作り直します。長いトークでは時間がかかります。', ok: '再生成');
    if (!ok) return;
    try {
      await state.rebuildMemory(s);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _editSynopsis(BuildContext context, AppState state, ChatSession s) async {
    final text = await _editText(context, 'あらすじ', s.memory.synopsis);
    if (text != null) state.setSynopsis(s, text);
  }
}

Future<void> _editFact(BuildContext context, AppState state, ChatSession s, MemoryItem? item) async {
  final controller = TextEditingController(text: item?.text ?? '');
  var importance = item?.importance ?? 3;
  var pinned = item?.pinned ?? true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(item == null ? '重要メモを追加' : '重要メモを編集'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '例: ミオとは週末に海へ行く約束をした'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('重要度'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 1, label: Text('低')),
                        ButtonSegment(value: 2, label: Text('中')),
                        ButtonSegment(value: 3, label: Text('高')),
                      ],
                      selected: {importance},
                      showSelectedIcon: false,
                      onSelectionChanged: (v) => setDialogState(() => importance = v.first),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('ピン留め (自動整理で消さない)'),
                value: pinned,
                onChanged: (v) => setDialogState(() => pinned = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    ),
  );
  if (ok == true && controller.text.trim().isNotEmpty) {
    if (item == null) {
      state.addFact(s, controller.text, importance: importance, pinned: pinned);
    } else {
      state.updateFact(s, item, text: controller.text, importance: importance, pinned: pinned);
    }
  }
  controller.dispose();
}

Future<String?> _editText(BuildContext context, String title, String initial) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 600,
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: 6,
          maxLines: 16,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('保存')),
      ],
    ),
  );
  controller.dispose();
  return result;
}

class _FactTile extends StatelessWidget {
  const _FactTile({required this.session, required this.item});

  final ChatSession session;
  final MemoryItem item;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    return ListTile(
      leading: IconButton(
        tooltip: item.pinned ? 'ピン留めを外す' : 'ピン留め',
        icon: Icon(item.pinned ? Icons.push_pin : Icons.push_pin_outlined),
        color: item.pinned ? theme.colorScheme.primary : null,
        onPressed: () => state.updateFact(session, item, pinned: !item.pinned),
      ),
      title: Text(item.text),
      subtitle: Text('重要度 ${'★' * item.importance}${'☆' * (3 - item.importance)}'),
      onTap: () => _editFact(context, state, session, item),
      trailing: IconButton(
        tooltip: '削除',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => state.deleteFact(session, item),
      ),
    );
  }
}
