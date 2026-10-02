import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import 'connect_page.dart';
import 'memory_page.dart';
import 'personas_page.dart';
import 'widgets.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  List<String> _suggestions = const [];
  bool _suggesting = false;

  /// グループトークで次に話させるキャラ。null なら順番に自動。
  String? _nextSpeakerId;

  @override
  void initState() {
    super.initState();
    // 開いたトークの記憶を追いつかせる (既存の長いトークは初回にまとめて作られる)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = AppScope.read(context);
      final s = _session(state);
      if (s != null) state.scheduleMemory(s, delay: const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  ChatSession? _session(AppState state) => state.sessions.where((s) => s.id == widget.sessionId).firstOrNull;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _send(AppState state, ChatSession s) async {
    final text = _input.text;
    if (state.isGenerating(s)) return;
    _input.clear();
    setState(() => _suggestions = const []);
    await _run(() => state.sendUserMessage(s, text, speaker: state.characterById(_nextSpeakerId)));
  }

  Future<void> _suggest(AppState state, ChatSession s) async {
    setState(() => _suggesting = true);
    try {
      final list = await state.suggestReplies(s);
      if (mounted) setState(() => _suggestions = list);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final s = _session(state);
    if (s == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('このトークは削除されました')),
      );
    }
    final cast = s.characterIds.map(state.characterById).nonNulls.toList();
    final generating = state.isGenerating(s);
    final persona = state.personaFor(s);
    final messages = s.messages;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            if (cast.isNotEmpty) CharacterAvatar(cast.first, radius: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.title, overflow: TextOverflow.ellipsis),
                  Text(
                    [
                      if (s.parentTitle != null) '分岐',
                      'あなた: ${persona?.name ?? '未設定'}',
                      ?state.settings.model,
                      if (state.isMemoryBusy(s)) '記憶を整理中…',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.labelSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'ユーザーノート',
            icon: Icon(s.userNote.trim().isEmpty ? Icons.sticky_note_2_outlined : Icons.sticky_note_2),
            onPressed: () => _editUserNote(state, s),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'memory':
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => MemoryPage(sessionId: s.id)));
                case 'persona':
                  await _choosePersona(state, s);
                case 'new':
                  final next = state.newSession(cast);
                  if (context.mounted) {
                    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatPage(sessionId: next.id)));
                  }
                case 'rename':
                  await _rename(state, s);
                case 'delete':
                  if (await confirm(context, 'トークを削除', 'このトークを削除しますか？', ok: '削除') && context.mounted) {
                    Navigator.pop(context);
                    state.deleteSession(s);
                  }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'memory',
                child: ListTile(leading: Icon(Icons.psychology_outlined), title: Text('記憶')),
              ),
              PopupMenuItem(
                value: 'persona',
                child: ListTile(leading: Icon(Icons.badge_outlined), title: Text('トークプロフィール')),
              ),
              PopupMenuItem(
                value: 'new',
                child: ListTile(leading: Icon(Icons.add_comment), title: Text('新しいトーク')),
              ),
              PopupMenuItem(
                value: 'rename',
                child: ListTile(leading: Icon(Icons.edit), title: Text('タイトル変更')),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(leading: Icon(Icons.delete_outline), title: Text('トークを削除')),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (state.connection != ConnectionStatus.connected)
              MaterialBanner(
                content: Text(
                  state.connection == ConnectionStatus.connecting ? 'LLM ホストに接続しています…' : 'LLM ホストに接続されていません',
                ),
                leading: const Icon(Icons.link_off),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectPage())),
                    child: const Text('接続する'),
                  ),
                ],
              ),
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                itemCount: messages.length,
                itemBuilder: (context, i) {
                  final index = messages.length - 1 - i;
                  final m = messages[index];
                  return _MessageBubble(
                    key: ValueKey(m.id),
                    session: s,
                    message: m,
                    isLast: index == messages.length - 1,
                    generating: generating && index == messages.length - 1,
                    onAction: (action) => _onMessageAction(state, s, m, action),
                  );
                },
              ),
            ),
            if (!generating && messages.isNotEmpty && messages.last.role == MessageRole.user)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: TextButton.icon(
                  onPressed: () =>
                      _run(() => state.sendUserMessage(s, '', speaker: state.characterById(_nextSpeakerId))),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('応答を生成'),
                ),
              ),
            if (_suggestions.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final text in _suggestions)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ActionChip(
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 280),
                            child: Text(text, overflow: TextOverflow.ellipsis),
                          ),
                          onPressed: () {
                            _input.text = text;
                            setState(() => _suggestions = const []);
                            _focus.requestFocus();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            if (s.isGroup) _speakerPicker(cast),
            _composer(state, s, generating),
          ],
        ),
      ),
    );
  }

  Widget _speakerPicker(List<Character> cast) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: const Text('順番に'),
              selected: _nextSpeakerId == null,
              onSelected: (_) => setState(() => _nextSpeakerId = null),
            ),
          ),
          for (final c in cast)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                avatar: CharacterAvatar(c, radius: 10),
                label: Text(c.name),
                selected: _nextSpeakerId == c.id,
                onSelected: (_) => setState(() => _nextSpeakerId = c.id),
              ),
            ),
        ],
      ),
    );
  }

  Widget _composer(AppState state, ChatSession s, bool generating) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: '返答のおすすめ',
            icon: _suggesting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.bolt),
            onPressed: (_suggesting || generating) ? null : () => _suggest(state, s),
          ),
          IconButton(
            tooltip: '描写 (*…*) を挿入',
            icon: const Icon(Icons.format_italic),
            onPressed: () {
              final sel = _input.selection;
              final text = _input.text;
              final start = sel.isValid ? sel.start : text.length;
              final end = sel.isValid ? sel.end : text.length;
              _input.value = TextEditingValue(
                text: '${text.substring(0, start)}*${text.substring(start, end)}*${text.substring(end)}',
                selection: TextSelection.collapsed(offset: end + 1),
              );
              _focus.requestFocus();
            },
          ),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                // デスクトップでは Ctrl+Enter / Cmd+Enter で送信
                const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _send(state, s),
                const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => _send(state, s),
              },
              child: TextField(
                controller: _input,
                focusNode: _focus,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: 'メッセージ (*描写* も使えます)',
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          generating
              ? IconButton.filledTonal(
                  tooltip: '停止',
                  icon: const Icon(Icons.stop),
                  onPressed: () => state.stopGeneration(s),
                )
              : IconButton.filled(tooltip: '送信', icon: const Icon(Icons.send), onPressed: () => _send(state, s)),
        ],
      ),
    );
  }

  Future<void> _onMessageAction(AppState state, ChatSession s, Message m, _MessageAction action) async {
    switch (action) {
      case _MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: m.content));
        if (mounted) showInfo(context, 'コピーしました');
      case _MessageAction.edit:
        final edited = await _editText(context, 'メッセージを編集', m.content);
        if (edited != null && edited.trim().isNotEmpty) state.editMessage(s, m, edited.trim());
      case _MessageAction.editResend:
        final edited = await _editText(
          context,
          '編集して送り直す',
          m.content,
          help: 'この発言を書き換えて、ここから会話をやり直します。以降の発言は消えます (残したい場合は先に「分岐」してください)。',
        );
        if (edited != null && edited.trim().isNotEmpty) {
          await _run(() => state.editAndResend(s, m, edited, speaker: state.characterById(_nextSpeakerId)));
        }
      case _MessageAction.rewind:
        if (await confirm(context, 'ここから削除', 'このメッセージ以降をすべて削除して、ここから会話をやり直しますか？', ok: '削除')) {
          state.rewindTo(s, m);
        }
      case _MessageAction.branch:
        final branch = state.branchSession(s, m);
        if (mounted) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatPage(sessionId: branch.id)));
        }
      case _MessageAction.regenerate:
        await _run(() => state.regenerate(s));
      case _MessageAction.continueText:
        await _run(() => state.continueLast(s));
      case _MessageAction.previous:
        if (m.selected > 0) state.selectAlternate(s, m, m.selected - 1);
      case _MessageAction.next:
        if (m.selected < m.alternates.length - 1) {
          state.selectAlternate(s, m, m.selected + 1);
        } else {
          // 最後の候補でさらに進めたら再生成する
          await _run(() => state.regenerate(s));
        }
    }
  }

  Future<void> _editUserNote(AppState state, ChatSession s) async {
    final text = await _editText(
      context,
      'ユーザーノート',
      s.userNote,
      help: 'このトークで AI に毎回渡す備忘録です。忘れてほしくない設定や出来事、呼び方などを書いておきます。',
    );
    if (text != null) {
      s.userNote = text;
      state.commit();
    }
  }

  Future<void> _rename(AppState state, ChatSession s) async {
    final text = await _editText(context, 'タイトル', s.title, maxLines: 1);
    if (text != null && text.trim().isNotEmpty) {
      s.title = text.trim();
      state.commit();
    }
  }

  Future<void> _choosePersona(AppState state, ChatSession s) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('このトークで使うトークプロフィール')),
          for (final p in state.personas)
            ListTile(
              leading: Icon(state.personaFor(s)?.id == p.id ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(p.name.isEmpty ? '(名前なし)' : p.name),
              subtitle: Text(p.description, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(context, p.id),
            ),
          ListTile(
            leading: const Icon(Icons.manage_accounts),
            title: const Text('トークプロフィールを管理'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(this.context, MaterialPageRoute(builder: (_) => const PersonasPage()));
            },
          ),
        ],
      ),
    );
    if (chosen != null) {
      s.personaId = chosen;
      state.commit();
    }
  }
}

Future<String?> _editText(BuildContext context, String title, String initial, {String? help, int maxLines = 12}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (help != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(help)),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: maxLines == 1 ? 1 : 4,
              maxLines: maxLines,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
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

enum _MessageAction { copy, edit, editResend, rewind, branch, regenerate, continueText, previous, next }

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.session,
    required this.message,
    required this.isLast,
    required this.generating,
    required this.onAction,
  });

  final ChatSession session;
  final Message message;
  final bool isLast;
  final bool generating;
  final ValueChanged<_MessageAction> onAction;

  Future<void> _showMenu(BuildContext context) async {
    final action = await showModalBottomSheet<_MessageAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('コピー'),
              onTap: () => Navigator.pop(context, _MessageAction.copy),
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('編集'),
              onTap: () => Navigator.pop(context, _MessageAction.edit),
            ),
            if (message.role == MessageRole.user)
              ListTile(
                leading: const Icon(Icons.replay),
                title: const Text('編集して送り直す'),
                onTap: () => Navigator.pop(context, _MessageAction.editResend),
              ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('ここまでで分岐 (新しいトーク)'),
              onTap: () => Navigator.pop(context, _MessageAction.branch),
            ),
            ListTile(
              leading: Icon(Icons.restore, color: Theme.of(context).colorScheme.error),
              title: const Text('ここから削除 (巻き戻し)'),
              onTap: () => Navigator.pop(context, _MessageAction.rewind),
            ),
          ],
        ),
      ),
    );
    if (action != null) onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.role == MessageRole.user;
    final character = isUser ? null : state.characterById(message.characterId);
    final showControls = !isUser && isLast && !generating;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isUser ? 18 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 18),
        ),
      ),
      child: message.content.isEmpty && generating
          ? const SizedBox(width: 32, height: 16, child: LinearProgressIndicator())
          : RoleplayText(
              message.content,
              style: TextStyle(
                fontSize: 15,
                height: 1.55,
                color: isUser ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
            ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[CharacterAvatar(character, radius: 18), const SizedBox(width: 8)],
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (!isUser)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 2),
                      child: Text(character?.name ?? '???', style: Theme.of(context).textTheme.labelMedium),
                    ),
                  GestureDetector(
                    onLongPress: generating ? null : () => _showMenu(context),
                    onSecondaryTap: generating ? null : () => _showMenu(context),
                    onHorizontalDragEnd: showControls
                        ? (d) {
                            final v = d.primaryVelocity ?? 0;
                            if (v < -200) onAction(_MessageAction.next);
                            if (v > 200) onAction(_MessageAction.previous);
                          }
                        : null,
                    child: bubble,
                  ),
                  if (showControls)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.chevron_left),
                          onPressed: message.selected > 0 ? () => onAction(_MessageAction.previous) : null,
                        ),
                        Text(
                          '${message.selected + 1} / ${message.alternates.length}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: message.selected < message.alternates.length - 1 ? '次の候補' : '別の応答を生成',
                          icon: const Icon(Icons.chevron_right),
                          onPressed: () => onAction(_MessageAction.next),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '再生成',
                          icon: const Icon(Icons.refresh),
                          onPressed: () => onAction(_MessageAction.regenerate),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '続きを書く',
                          icon: const Icon(Icons.more_horiz),
                          onPressed: () => onAction(_MessageAction.continueText),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
