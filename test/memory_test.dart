import 'package:flutter_test/flutter_test.dart';
import 'package:stollmly/memory/embedding_store.dart';
import 'package:stollmly/memory/memory_logic.dart';
import 'package:stollmly/memory/memory_models.dart';
import 'package:stollmly/memory/memory_service.dart';
import 'package:stollmly/models.dart';
import 'package:stollmly/net/host_client.dart';
import 'package:stollmly/prompt.dart';

List<Message> conversation(int n, {String prefix = 'メッセージ'}) => [
  for (var i = 0; i < n; i++)
    Message(
      id: 'm$i',
      role: i.isEven ? MessageRole.user : MessageRole.character,
      characterId: i.isEven ? null : 'c',
      alternates: ['$prefix$i'],
    ),
];

/// 要約・抽出・統合のプロンプトを見分けて決まった応答を返す偽の LLM。
class FakeGateway implements MemoryGateway {
  int summaries = 0;
  int factUpdates = 0;
  int compressions = 0;
  int folds = 0;
  bool embedFails = false;
  String Function(String log)? factsFor;
  Map<String, List<double>> vectors = {};

  @override
  Future<String> complete(List<ChatTurn> turns, {int maxTokens = 1024, double temperature = 0.3}) async {
    final system = turns.first.content;
    final user = turns.last.content;
    if (system.contains('時系列で 300 字')) {
      summaries++;
      final ids = RegExp(r'メッセージ(\d+)').allMatches(user).map((m) => m.group(1)).toList();
      return '要約 ${ids.first}-${ids.last}';
    }
    if (system.contains('最新のメモ')) {
      factUpdates++;
      return factsFor?.call(user) ?? '- [重要度3] 事実$factUpdates';
    }
    if (system.contains('圧縮')) {
      compressions++;
      return '- [重要度3] 圧縮済み';
    }
    if (system.contains('物語全体のあらすじ')) {
      folds++;
      return 'あらすじ v$folds';
    }
    throw StateError('unexpected prompt');
  }

  @override
  Future<List<List<double>>> embed(String model, List<String> inputs) async {
    if (embedFails) throw HostException('model "$model" not found');
    return [
      for (final t in inputs) vectors[t] ?? const [0.0, 0.0, 0.0, 1.0],
    ];
  }
}

void main() {
  group('prefixHash', () {
    test('本文の編集・発言の削除で変わり、それ以外では変わらない', () {
      final a = conversation(10);
      final b = conversation(10);
      expect(prefixHash(a, 6), prefixHash(b, 6));
      b[3].content = '書き換え';
      expect(prefixHash(a, 6), isNot(prefixHash(b, 6)));
      expect(prefixHash(a, 3), prefixHash(b, 3)); // 編集より前は同じ
      final c = conversation(10)..removeAt(2);
      expect(prefixHash(a, 6), isNot(prefixHash(c, 6)));
    });
  });

  group('区切りとあらすじ', () {
    test('区切りは件数がたまってから。末尾 2 件は含めない', () {
      expect(planNextChunk(covered: 0, total: 41, chunkMessages: 40), isNull);
      expect(planNextChunk(covered: 0, total: 42, chunkMessages: 40), (0, 40));
      expect(planNextChunk(covered: 40, total: 100, chunkMessages: 40), (40, 80));
      expect(planNextChunk(covered: 80, total: 100, chunkMessages: 40), isNull);
    });

    test('次の整理までの往復数', () {
      expect(turnsUntilNextChunk(covered: 0, total: 3, chunkMessages: 40), 20);
      expect(turnsUntilNextChunk(covered: 0, total: 41, chunkMessages: 40), 1);
      expect(turnsUntilNextChunk(covered: 0, total: 42, chunkMessages: 40), 0);
      expect(turnsUntilNextChunk(covered: 40, total: 45, chunkMessages: 40), 19);
    });

    test('あらすじは区切りがたまるか、追いついたときに畳み込む', () {
      expect(shouldFoldSynopsis(unfolded: 0, hasMoreChunks: false), isFalse);
      expect(shouldFoldSynopsis(unfolded: 1, hasMoreChunks: false), isTrue);
      expect(shouldFoldSynopsis(unfolded: 4, hasMoreChunks: true), isFalse);
      expect(shouldFoldSynopsis(unfolded: 5, hasMoreChunks: true), isTrue);
    });
  });

  group('重要メモ', () {
    test('箇条書きと重要度を読み取る', () {
      final items = parseFacts('''
メモ:
- [重要度3] ハルはミオの幼なじみ
・[2] 好物はクレープ
* 週末に海へ行く約束
1. [重要度：1] 傘を忘れた
- [重要度3] ハルはミオの幼なじみ
''');
      expect([for (final f in items) f.text], ['ハルはミオの幼なじみ', '好物はクレープ', '週末に海へ行く約束', '傘を忘れた']);
      expect([for (final f in items) f.importance], [3, 2, 2, 1]);
    });

    test('小型モデルの崩れた出力: 地の文・見出しの書き写し・括弧なしの重要度', () {
      final items = parseFacts('''
- **固定メモ**: 今週末、島のビーチを楽しみたい。

- **新しい会話**: 白瀬ミオ: お腹を空いて泳ぎ回る。
*ミオは、お腹を空いて泳ぎ回る。*
- 重要度 1 内容: 「今週末は、泳ぎに行く計画を立てている。」
- 重要度 3 内容: 「ミオは、雷が苦手だ。」
- 重要度 7 内容: 「By the way, call me Haru from now on。」
- 重要度 10 内容: 「ミオは、雷が苦手だ。」
- **ハル**はミオの幼なじみ
''');
      expect(
        [for (final f in items) f.text],
        ['今週末は、泳ぎに行く計画を立てている。', 'ミオは、雷が苦手だ。', 'By the way, call me Haru from now on。', 'ハルはミオの幼なじみ'],
      );
      expect([for (final f in items) f.importance], [1, 3, 2, 2]);
    });

    test('統合: ピン留めは残り、同じ文面は ID を引き継ぎ、空の出力なら以前のまま', () {
      final pinned = MemoryItem(text: '名前はハル', pinned: true);
      final keep = MemoryItem(text: '好物はクレープ');
      final previous = [pinned, keep, MemoryItem(text: '古い事実')];

      final merged = mergeFacts(previous: previous, updated: parseFacts('- [重要度2] 好物はクレープ\n- [重要度3] 新しい約束'));
      expect([for (final f in merged) f.text], ['名前はハル', '好物はクレープ', '新しい約束']);
      expect(merged[1].id, keep.id);
      expect(merged.first.pinned, isTrue);

      expect(mergeFacts(previous: previous, updated: const []).length, 3);
    });

    test('上限超過は重要度の低い順・新しい順に削り、ピン留めは消さない', () {
      final items = [
        MemoryItem(text: 'A' * 10, importance: 1, pinned: true),
        MemoryItem(text: 'B' * 10, importance: 3),
        MemoryItem(text: 'C' * 10, importance: 1),
        MemoryItem(text: 'D' * 10, importance: 2),
        MemoryItem(text: 'E' * 10, importance: 1),
      ];
      final limited = enforceFactsLimit(items, 30);
      expect([for (final f in limited) f.text[0]], ['A', 'B', 'D']);
      expect(enforceFactsLimit(items, 1000).length, 5);
      expect(enforceFactsLimit(items, 5).map((f) => f.text[0]), ['A']);
    });
  });

  group('巻き戻しと分岐', () {
    SessionMemory memoryAt(List<Message> messages, List<int> boundaries) {
      final mem = SessionMemory();
      var start = 0;
      for (final end in boundaries) {
        mem.chunks.add(ChunkSummary(start: start, end: end, summary: '要約$end'));
        mem.facts
          ..clear()
          ..add(MemoryItem(text: '事実$end'));
        mem.synopsis = 'あらすじ$end';
        mem.foldedChunks = mem.chunks.length;
        mem.checkpoints.add(makeCheckpoint(mem, messages));
        start = end;
      }
      return mem;
    }

    test('変更が無ければ何もしない', () {
      final messages = conversation(50);
      final mem = memoryAt(messages, [20, 40]);
      expect(reconcileMemory(mem, messages), isFalse);
      expect(mem.coveredCount, 40);
    });

    test('要約済みの発言を編集すると、その前のチェックポイントまで戻る。ピン留めは残る', () {
      final messages = conversation(50);
      final mem = memoryAt(messages, [20, 40]);
      mem.facts.add(MemoryItem(text: '大事', pinned: true));
      messages[25].content = '編集した';

      expect(reconcileMemory(mem, messages), isTrue);
      expect(mem.coveredCount, 20);
      expect(mem.synopsis, 'あらすじ20');
      expect([for (final f in mem.facts) f.text], ['事実20', '大事']);
      expect(mem.checkpoints.length, 1);
    });

    test('先頭付近まで巻き戻すと空からやり直す', () {
      final messages = conversation(50);
      final mem = memoryAt(messages, [20, 40]);
      messages.removeRange(10, messages.length);
      expect(reconcileMemory(mem, messages), isTrue);
      expect(mem.coveredCount, 0);
      expect(mem.synopsis, isEmpty);
      expect(mem.facts, isEmpty);
    });

    test('分岐先には分岐点までの記憶だけを引き継ぐ', () {
      final messages = conversation(50);
      final source = memoryAt(messages, [20, 40]);
      final branch = memoryForBranch(source, [for (final m in messages.take(30)) m.copy()]);
      expect(branch.coveredCount, 20);
      expect(branch.synopsis, 'あらすじ20');
      expect(source.coveredCount, 40); // 元は変わらない
    });
  });

  group('直近の範囲と検索', () {
    test('直近 N 往復に加えて、未要約の発言も必ず入れる。文字数の上限で削る', () {
      final lengths = List.filled(100, 10);
      expect(recentWindowStart(lengths: lengths, recentTurns: 6, covered: 100, maxChars: 10000), 88);
      expect(recentWindowStart(lengths: lengths, recentTurns: 6, covered: 80, maxChars: 10000), 80);
      expect(recentWindowStart(lengths: lengths, recentTurns: 6, covered: 0, maxChars: 150), 85);
      expect(recentWindowStart(lengths: [5000, 5000, 5000], recentTurns: 6, covered: 0, maxChars: 100), 1);
    });

    test('量子化してもコサイン類似度の順序は保たれる', () {
      final a = quantize([1, 0, 0, 0]);
      final b = quantize([0.9, 0.1, 0, 0]);
      final c = quantize([0, 1, 0, 0]);
      expect(cosine(a, b), greaterThan(cosine(a, c)));
      expect(cosine(a, a), closeTo(1, 1e-6));
    });

    test('直近の範囲を除き、しきい値以上の上位 K 件を時系列順で返す', () {
      final q = quantize([1, 0, 0]);
      final candidates = {
        0: quantize([0.9, 0.1, 0]),
        1: quantize([0, 1, 0]),
        2: quantize([1, 0, 0]),
        3: quantize([0.7, 0.7, 0]),
        4: quantize([0.95, 0.05, 0]),
        9: quantize([1, 0, 0]),
      };
      expect(selectRetrieved(query: q, candidates: candidates, before: 8, topK: 3), [0, 2, 4]);
      expect(selectRetrieved(query: q, candidates: candidates, before: 8, topK: 3, minScore: 0.999), [2]);
      expect(selectRetrieved(query: q, candidates: candidates, before: 2, topK: 3), [0]);
    });
  });

  group('プロンプトの組み立て', () {
    final mio = Character(id: 'c', name: 'ミオ', prompt: '幼なじみ');
    PromptBuilder builder(ChatSession s) => PromptBuilder(
      session: s,
      characters: {'c': mio},
      speaker: mio,
      persona: Persona(name: 'ハル'),
      contextChars: 100000,
      outputFormat: '出力フォーマット',
    );

    test('固定部分 → ユーザーノート → 重要メモ → あらすじ → 過去の発言 → 直近の順', () {
      final messages = conversation(30);
      final s = ChatSession(characterIds: ['c'], userNote: 'ノート', messages: messages);
      final mem = SessionMemory(
        facts: [MemoryItem(text: '約束がある')],
        synopsis: 'これまでの話',
      );
      final turns = builder(s).build(messages, memory: mem, recentStart: 26, retrieved: [messages[3]]);
      final system = turns.first.content;

      final order = ['出力フォーマット', '# ユーザーノート', '# 重要メモ', '# これまでのあらすじ', '# 関連する過去の発言'];
      final positions = [for (final h in order) system.indexOf(h)];
      expect(positions.every((p) => p >= 0), isTrue);
      expect([...positions]..sort(), positions);
      expect(system, contains('- 約束がある'));
      expect(system, contains('ミオ: メッセージ3'));
      // 直近 4 件だけが会話として入る
      expect(turns.skip(1).map((t) => t.content).join(), allOf(contains('メッセージ26'), isNot(contains('メッセージ25'))));
    });

    test('先頭の固定部分は記憶や履歴が変わっても同じ (プレフィックスキャッシュが効く)', () {
      final s = ChatSession(characterIds: ['c'], messages: conversation(30));
      final a = builder(s).build(s.messages, memory: SessionMemory(synopsis: 'A'), recentStart: 20).first.content;
      final b = builder(s)
          .build(s.messages.take(10).toList(), memory: SessionMemory(synopsis: 'B'), recentStart: 4)
          .first
          .content;
      final prefix = builder(s).fixedPrefix().trim();
      expect(a.startsWith(prefix), isTrue);
      expect(b.startsWith(prefix), isTrue);
    });
  });

  group('MemoryService', () {
    late FakeGateway gateway;
    late InMemoryEmbeddingStore store;
    late MemoryConfig config;
    late MemoryService service;
    String nameOf(Message m) => m.role == MessageRole.user ? 'ハル' : 'ミオ';

    setUp(() {
      gateway = FakeGateway();
      store = InMemoryEmbeddingStore();
      config = const MemoryConfig(interval: 5, factsMaxChars: 100); // 10 発言ごと
      service = MemoryService(gateway: gateway, store: store, config: () => config, onChanged: () {});
    });

    test('既存の長い履歴をまとめて処理し、区切りごとに要約・抽出、あらすじは最後にまとめて畳み込む', () async {
      final s = ChatSession(characterIds: ['c'], messages: conversation(43));
      await service.process(s, nameOf);

      expect(s.memory.coveredCount, 40);
      expect(gateway.summaries, 4);
      expect(gateway.factUpdates, 4);
      expect(gateway.folds, 1); // 4 区切りを一度に畳み込む
      expect(s.memory.synopsis, 'あらすじ v1');
      expect(s.memory.chunks.map((c) => c.summary), ['要約 0-9', '要約 10-19', '要約 20-29', '要約 30-39']);
      expect(s.memory.facts.single.text, '事実4');
      expect(s.memory.checkpoints.length, 4);
      expect(store.data[s.id]!.length, 43);
      // 4 文字未満の発言は検索の役に立たないので embedding を作らない
      s.messages.add(Message(id: 'short', role: MessageRole.user, alternates: ['うん']));

      // 区切りに届かなければ LLM は呼ばない
      await service.process(s, nameOf);
      expect(gateway.summaries, 4);
      expect(store.data[s.id]!.containsKey('short'), isFalse);
    });

    test('要約済みの発言を編集すると、その区切りから作り直す', () async {
      final s = ChatSession(characterIds: ['c'], messages: conversation(43));
      await service.process(s, nameOf);
      s.messages[25].content = 'メッセージ25 (編集)';

      await service.process(s, nameOf);
      expect(s.memory.coveredCount, 40);
      expect(gateway.summaries, 6); // 20-29 と 30-39 を作り直す
      expect(s.memory.checkpoints.map((c) => c.count), [10, 20, 30, 40]);
      expect(latestValidCheckpoint(s.memory.checkpoints, s.messages)!.count, 40);
    });

    test('上限を超えたメモは圧縮し、それでも超えれば重要度の低いものから削る', () async {
      gateway.factsFor = (_) => [for (var i = 0; i < 20; i++) '- [重要度${i % 3 + 1}] ${'長い事実$i' * 3}'].join('\n');
      final s = ChatSession(characterIds: ['c'], messages: conversation(12));
      s.memory.facts.add(MemoryItem(text: 'ピン留めの事実', pinned: true));
      await service.process(s, nameOf);

      expect(gateway.compressions, 1);
      expect(totalChars(s.memory.facts), lessThanOrEqualTo(100));
      expect(s.memory.facts.map((f) => f.text), containsAll(['ピン留めの事実', '圧縮済み']));
    });

    test('embedding が使えなくても要約と重要メモは動き、検索だけ無効になる', () async {
      gateway.embedFails = true;
      final s = ChatSession(characterIds: ['c'], messages: conversation(22));
      await service.process(s, nameOf);

      expect(s.memory.coveredCount, 20);
      expect(service.retrievalAvailable, isFalse);
      expect(service.retrievalUnavailableReason, contains('not found'));
      expect(await service.retrieve(s, s.messages, before: 10, query: 'クレープ'), isEmpty);

      service.resetRetrieval();
      expect(service.retrievalAvailable, isTrue);
    });

    test('検索: 直近より前から意味の近い発言を選ぶ', () async {
      final s = ChatSession(characterIds: ['c'], messages: conversation(20));
      gateway.vectors = {
        'ハル: メッセージ4': [1, 0, 0, 0],
        'ミオ: メッセージ7': [0.9, 0.2, 0, 0],
        'クレープ': [1, 0, 0, 0],
      };
      await service.process(s, nameOf);
      final hits = await service.retrieve(s, s.messages, before: 12, query: 'クレープ');
      expect(hits.map((m) => m.id), ['m4', 'm7']);
    });

    test('チャット優先で中断されても状態は壊れず、次回続きから処理する', () async {
      var calls = 0;
      final cancelling = _CancellingGateway(gateway, cancelAfter: () => ++calls > 2);
      final svc = MemoryService(gateway: cancelling, store: store, config: () => config, onChanged: () {});
      final s = ChatSession(characterIds: ['c'], messages: conversation(43));
      await svc.process(s, nameOf);
      expect(s.memory.coveredCount, 10);
      expect(svc.isRunning(s.id), isFalse);

      await service.process(s, nameOf);
      expect(s.memory.coveredCount, 40);
    });

    test('分岐先は分岐点までの記憶と embedding を引き継ぐ', () async {
      final source = ChatSession(characterIds: ['c'], messages: conversation(43));
      await service.process(source, nameOf);
      final branch = ChatSession(characterIds: ['c'], messages: [for (final m in source.messages.take(25)) m.copy()]);
      await service.inheritForBranch(source, branch);

      expect(branch.memory.coveredCount, 20);
      expect(branch.memory.checkpoints.map((c) => c.count), [10, 20]);
      expect(store.data[branch.id]!.keys.toSet(), {for (final m in branch.messages) m.id});
    });
  });
}

class _CancellingGateway implements MemoryGateway {
  _CancellingGateway(this.inner, {required this.cancelAfter});

  final MemoryGateway inner;
  final bool Function() cancelAfter;

  @override
  Future<String> complete(List<ChatTurn> turns, {int maxTokens = 1024, double temperature = 0.3}) {
    if (cancelAfter()) throw const MemoryCancelled();
    return inner.complete(turns, maxTokens: maxTokens, temperature: temperature);
  }

  @override
  Future<List<List<double>>> embed(String model, List<String> inputs) => inner.embed(model, inputs);
}
