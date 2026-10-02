import 'package:flutter_test/flutter_test.dart';
import 'package:stollmly/models.dart';
import 'package:stollmly/prompt.dart';
import 'package:stollmly/update/updater.dart';

void main() {
  group('Updater.isNewer', () {
    test('ISO 8601 基本形式のタグは時刻順に比較される', () {
      expect(Updater.isNewer('alpha-20261002T120000Z', 'alpha-20261001T235959Z'), isTrue);
      expect(Updater.isNewer('alpha-20261001T000000Z', 'alpha-20261002T000000Z'), isFalse);
      expect(Updater.isNewer('alpha-20261002T120000Z', 'alpha-20261002T120000Z'), isFalse);
    });

    test('dev ビルドからは常に更新対象、alpha 以外のタグは無視', () {
      expect(Updater.isNewer('alpha-20261002T120000Z', 'dev'), isTrue);
      expect(Updater.isNewer('v1.0.0', 'alpha-20261002T120000Z'), isFalse);
    });
  });

  group('PromptBuilder', () {
    final mio = Character(
      name: 'ミオ',
      prompt: '{{char}} は {{user}} の幼なじみ',
      lore: [
        LoreEntry(title: '駅前', keywords: ['クレープ'], content: '駅前にはクレープ屋がある'),
        LoreEntry(title: '秘密', keywords: ['宝箱'], content: '出てはいけない'),
      ],
    );
    final persona = Persona(name: 'ハル', description: '高校生');

    ChatSession session(List<Message> messages) =>
        ChatSession(characterIds: [mio.id], userNote: '雷が苦手', messages: messages);

    test('設定・ペルソナ・ユーザーノート・該当ロアだけが system に入る', () {
      final s = session([
        Message(role: MessageRole.character, characterId: mio.id, alternates: ['*手を振る* おはよ']),
        Message(role: MessageRole.user, alternates: ['クレープ食べに行こう']),
      ]);
      final turns = PromptBuilder(
        session: s,
        characters: {mio.id: mio},
        speaker: mio,
        persona: persona,
        contextChars: 10000,
      ).build(s.messages);

      final system = turns.first.content;
      expect(turns.first.role, 'system');
      expect(system, contains('ミオ は ハル の幼なじみ'));
      expect(system, contains('高校生'));
      expect(system, contains('雷が苦手'));
      expect(system, contains('駅前にはクレープ屋がある'));
      expect(system, isNot(contains('出てはいけない')));
      // イントロ (assistant) が先頭に来たら user ターンを補う
      expect(turns.map((t) => t.role), ['system', 'user', 'assistant', 'user']);
    });

    test('履歴は contextChars を超えたら古い方から落とす', () {
      final s = session([
        for (var i = 0; i < 10; i++) Message(role: MessageRole.user, alternates: ['x' * 100]),
      ]);
      final turns = PromptBuilder(
        session: s,
        characters: {mio.id: mio},
        speaker: mio,
        persona: persona,
        contextChars: 350,
      ).build(s.messages);
      // 連続する user ターンは 1 つにまとめられる
      expect(turns.length, 2);
      expect('x'.allMatches(turns[1].content).length, 300);
    });

    test('返答候補のパース', () {
      expect(PromptBuilder.parseSuggestions('1. いいよ\n2) 嫌だ\n- 「考えとく」\n4. 余分'), ['いいよ', '嫌だ', '考えとく']);
    });
  });

  test('名前の接頭辞を取り除く', () {
    expect(stripSpeakerPrefix('ミオ: やっほー', 'ミオ'), 'やっほー');
    expect(stripSpeakerPrefix('[ミオ]：やっほー', 'ミオ'), 'やっほー');
    expect(stripSpeakerPrefix('やっほー ミオ: です', 'ミオ'), 'やっほー ミオ: です');
  });

  test('Character の JSON 往復', () {
    final c = Character(
      name: 'A',
      tags: ['t'],
      lore: [
        LoreEntry(keywords: ['k'], content: 'c'),
      ],
      pov: NarrationPov.first,
    );
    final back = Character.fromJson(c.toJson());
    expect(back.toJson(), c.toJson());
  });
}
