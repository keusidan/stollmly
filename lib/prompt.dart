import 'models.dart';
import 'net/host_client.dart';

/// 同梱の出力フォーマット。{{char}} {{user}} {{pov}} {{tempo}} {{openness}} {{length}} が置き換わる。
const outputFormatAsset = 'assets/prompts/output_format.md';

/// キャラクター設定・トークプロフィール・ユーザーノート・ロアブロック・出力フォーマット・履歴から
/// OpenAI 互換の messages を組み立てる。
class PromptBuilder {
  PromptBuilder({
    required this.session,
    required this.characters,
    required this.speaker,
    required this.persona,
    required this.contextChars,
    required this.outputFormat,
  });

  final ChatSession session;

  /// セッションに参加している全キャラクター (id → Character)。
  final Map<String, Character> characters;

  /// 今回発言させるキャラクター。
  final Character speaker;
  final Persona? persona;
  final int contextChars;

  /// 出力フォーマットの指示 (assets/prompts/output_format.md か、ユーザーが編集したもの)。
  final String outputFormat;

  String get _userName => (persona?.name.trim().isNotEmpty ?? false) ? persona!.name.trim() : 'ユーザー';

  String _fill(String text) => text
      .replaceAll('{{char}}', speaker.name)
      .replaceAll('{{user}}', _userName)
      .replaceAll('{{pov}}', speaker.pov.instruction)
      .replaceAll('{{tempo}}', speaker.tempo.instruction)
      .replaceAll('{{openness}}', speaker.openness.instruction)
      .replaceAll('{{length}}', speaker.replyLength.instruction);

  /// [history] は今回の応答より前の発言 (末尾が最新)。
  List<ChatTurn> build(List<Message> history) {
    final trimmed = _trimHistory(history);
    final recentText = trimmed.reversed.take(8).map((m) => m.content).join('\n');

    final system = StringBuffer()
      ..writeln('これは創作ロールプレイです。あなたは「${speaker.name}」を演じ、$_userName と物語を紡ぎます。')
      ..writeln()
      ..writeln('# ${speaker.name} の設定')
      ..writeln(_fill(speaker.prompt).trim().isEmpty ? '(設定なし)' : _fill(speaker.prompt).trim());

    if (session.isGroup) {
      final others = session.characterIds.where((id) => id != speaker.id).map((id) => characters[id]).nonNulls;
      system
        ..writeln()
        ..writeln('# 同じ場面にいる他の登場人物');
      for (final c in others) {
        system.writeln('- ${c.name}: ${c.tagline.isNotEmpty ? c.tagline : _firstLine(c.prompt)}');
      }
    }

    final lore = <LoreEntry>[for (final id in session.characterIds) ...?characters[id]?.lore]
        .where((l) => l.content.trim().isNotEmpty && l.matches(recentText))
        .toList();
    if (lore.isNotEmpty) {
      system
        ..writeln()
        ..writeln('# 世界観・関連設定');
      for (final l in lore) {
        system.writeln('- ${l.title.isNotEmpty ? '${l.title}: ' : ''}${_fill(l.content).trim()}');
      }
    }

    if (persona != null && persona!.description.trim().isNotEmpty) {
      system
        ..writeln()
        ..writeln('# $_userName (ユーザー) について')
        ..writeln(persona!.description.trim());
    }

    if (session.userNote.trim().isNotEmpty) {
      system
        ..writeln()
        ..writeln('# ユーザーノート (必ず守る・覚えておく事項)')
        ..writeln(session.userNote.trim());
    }

    if (speaker.exampleDialogue.trim().isNotEmpty) {
      system
        ..writeln()
        ..writeln('# 口調の例')
        ..writeln(_fill(speaker.exampleDialogue).trim());
    }

    system
      ..writeln()
      ..writeln(_fill(outputFormat).trim());

    final turns = <ChatTurn>[ChatTurn('system', system.toString().trim())];
    for (final m in trimmed) {
      if (m.content.trim().isEmpty) continue;
      if (m.role == MessageRole.character && m.characterId == speaker.id) {
        turns.add(ChatTurn('assistant', m.content));
      } else if (m.role == MessageRole.character) {
        final name = characters[m.characterId]?.name ?? '???';
        turns.add(ChatTurn('user', '[$name]\n${m.content}'));
      } else {
        turns.add(ChatTurn('user', session.isGroup ? '[$_userName]\n${m.content}' : m.content));
      }
    }
    // 先頭がイントロ (assistant) のときなど、user から始まらないモデル向けの保険
    if (turns.length > 1 && turns[1].role == 'assistant') {
      turns.insert(1, const ChatTurn('user', '(物語を始めてください)'));
    }
    if (turns.last.role == 'assistant') {
      turns.add(const ChatTurn('user', '(続けてください)'));
    }
    return _mergeConsecutive(turns);
  }

  /// 返答候補 (⚡ ボタン) 用のプロンプト。
  List<ChatTurn> buildSuggestions(List<Message> history) {
    final trimmed = _trimHistory(history);
    final log = StringBuffer();
    for (final m in trimmed.skip(trimmed.length > 12 ? trimmed.length - 12 : 0)) {
      final name = m.role == MessageRole.user ? _userName : (characters[m.characterId]?.name ?? '???');
      log.writeln('$name: ${m.content}');
    }
    return [
      ChatTurn(
        'system',
        'あなたはロールプレイの補助役です。以下の会話の続きとして、$_userName が次に言いそうな返答を'
            '3 つ、方向性を変えて提案してください。1 行に 1 つ、番号や説明を付けずに出力してください。'
            '${persona?.description.trim().isNotEmpty ?? false ? '\n$_userName の設定: ${persona!.description.trim()}' : ''}',
      ),
      ChatTurn('user', '会話:\n$log\n$_userName の返答候補を 3 行で:'),
    ];
  }

  static List<String> parseSuggestions(String text) {
    final cleaned = text
        .split('\n')
        .map((l) => l.trim().replaceFirst(RegExp(r'^((\d+[\.\)、:]|[-・*]|「)\s*)+'), '').replaceFirst(RegExp(r'」$'), ''))
        .where((l) => l.isNotEmpty)
        .toList();
    return cleaned.take(3).toList();
  }

  List<Message> _trimHistory(List<Message> history) {
    var budget = contextChars;
    final kept = <Message>[];
    for (final m in history.reversed) {
      budget -= m.content.length;
      if (budget < 0 && kept.isNotEmpty) break;
      kept.add(m);
    }
    return kept.reversed.toList();
  }

  static List<ChatTurn> _mergeConsecutive(List<ChatTurn> turns) {
    final merged = <ChatTurn>[];
    for (final t in turns) {
      if (merged.isNotEmpty && merged.last.role == t.role && t.role != 'system') {
        merged[merged.length - 1] = ChatTurn(t.role, '${merged.last.content}\n\n${t.content}');
      } else {
        merged.add(t);
      }
    }
    return merged;
  }

  static String _firstLine(String s) {
    final line = s.trim().split('\n').first;
    return line.length > 60 ? '${line.substring(0, 60)}…' : line;
  }
}

/// モデルが付けがちな「名前:」接頭辞を取り除く。
String stripSpeakerPrefix(String text, String name) {
  final pattern = RegExp('^\\s*(\\[?${RegExp.escape(name)}\\]?\\s*[:：]\\s*)');
  return text.replaceFirst(pattern, '');
}
