import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stollmly/models.dart';
import 'package:stollmly/prompt.dart';
import 'package:stollmly/sample_data.dart';
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

  group('Updater.pickLatest', () {
    ReleaseInfo release(String tag, List<String> assets, {bool prerelease = false}) => ReleaseInfo(
      tag: tag,
      name: tag,
      body: '',
      htmlUrl: Uri.parse('https://example.com/$tag'),
      publishedAt: null,
      assets: [for (final a in assets) ReleaseAsset(name: a, url: Uri.parse('https://example.com/$a'), size: 1)],
      prerelease: prerelease,
    );

    test('自分のプラットフォームのアセットを含む最新リリースを選ぶ', () {
      final releases = [
        release('alpha-20261003T000000Z', ['stollmly-ios-unsigned.ipa']),
        release('alpha-20261001T000000Z', ['stollmly-android.apk', 'stollmly-ios-unsigned.ipa']),
        release('alpha-20261002T000000Z', ['stollmly-android.apk']),
      ];
      expect(Updater.pickLatest(releases, 'stollmly-android.apk')?.tag, 'alpha-20261002T000000Z');
      expect(Updater.pickLatest(releases, 'stollmly-ios-unsigned.ipa')?.tag, 'alpha-20261003T000000Z');
      expect(Updater.pickLatest(releases, 'stollmly-macos.zip'), isNull);
    });

    test('既定では main のビルドだけ、設定でオンなら他ブランチ (prerelease) も選ぶ', () {
      final releases = [
        release('alpha-20261002T000000Z', ['stollmly-android.apk']),
        release('alpha-20261003T000000Z', ['stollmly-android.apk'], prerelease: true),
      ];
      expect(Updater.pickLatest(releases, 'stollmly-android.apk')?.tag, 'alpha-20261002T000000Z');
      expect(
        Updater.pickLatest(releases, 'stollmly-android.apk', includeBranches: true)?.tag,
        'alpha-20261003T000000Z',
      );
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
        outputFormat: '視点は{{pov}}。{{char}}は{{user}}に話しかける。',
      ).build(s.messages);

      final system = turns.first.content;
      expect(turns.first.role, 'system');
      expect(system, contains('ミオ は ハル の幼なじみ'));
      expect(system, contains('高校生'));
      expect(system, contains('雷が苦手'));
      expect(system, contains('駅前にはクレープ屋がある'));
      expect(system, isNot(contains('出てはいけない')));
      // 出力フォーマットのプレースホルダーが置き換わる
      expect(system, contains('視点は${NarrationPov.third.instruction}。ミオはハルに話しかける。'));
      expect(system, isNot(contains('{{')));
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
        outputFormat: '',
      ).build(s.messages);
      // 連続する user ターンは 1 つにまとめられる
      expect(turns.length, 2);
      expect('x'.allMatches(turns[1].content).length, 300);
    });

    test('返答候補のパース', () {
      expect(PromptBuilder.parseSuggestions('1. いいよ\n2) 嫌だ\n- 「考えとく」\n4. 余分'), ['いいよ', '嫌だ', '考えとく']);
    });

    test('返答候補の行ラベルと重複を取り除く (小型モデルの実際の出力)', () {
      expect(PromptBuilder.parseSuggestions('1 行: なぜ、なぜ？\n2 行: なぜなら、ここにいたの。\n3行目：ほんと？'), [
        'なぜ、なぜ？',
        'なぜなら、ここにいたの。',
        'ほんと？',
      ]);
      expect(PromptBuilder.parseSuggestions('行いますか？\n行きますか?\n行いますか？\n行いますか?'), ['行いますか？', '行きますか?', '行いますか?']);
      expect(PromptBuilder.parseSuggestions('あなた: お手伝い。\n1行目: あなた：行こうか', userName: 'あなた'), ['お手伝い。', '行こうか']);
    });
  });

  test('同梱の出力フォーマットは未知のプレースホルダーを含まない', () {
    final text = File('assets/prompts/output_format.md').readAsStringSync();
    final used = RegExp(r'\{\{(\w+)\}\}').allMatches(text).map((m) => m.group(1)).toSet();
    expect(used.difference({'char', 'user', 'pov', 'tempo', 'openness', 'length'}), isEmpty);
  });

  test('名前の接頭辞を取り除く', () {
    expect(stripSpeakerPrefix('ミオ: やっほー', 'ミオ'), 'やっほー');
    expect(stripSpeakerPrefix('[ミオ]：やっほー', 'ミオ'), 'やっほー');
    expect(stripSpeakerPrefix('やっほー ミオ: です', 'ミオ'), 'やっほー ミオ: です');
  });

  test('サンプルキャラは白瀬 ミオが先頭に並ぶ (更新日時が新しい順)', () {
    final samples = sampleCharacters()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    expect(samples.first.name, '白瀬 ミオ');
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
