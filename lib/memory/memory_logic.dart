// 長期記憶の純粋なロジック (I/O なし。ユニットテストの対象)。
import 'dart:math';
import 'dart:typed_data';

import '../models.dart';
import '../net/host_client.dart';
import 'memory_models.dart';

// ---------------------------------------------------------------- 発言ハッシュ

/// 先頭 [count] 件の発言 (id と選択中の本文) の FNV-1a 64bit ハッシュ。
/// 編集・削除・スワイプで本文や並びが変わると値が変わる。
String prefixHash(List<Message> messages, int count) {
  // FNV-1a のオフセット基底 0xcbf29ce484222325 を符号付き 64bit で表したもの (Dart の int は 64bit で桁あふれは折り返す)
  var h = -3750763034362895579;
  const prime = 0x100000001b3;
  void add(int byte) {
    h ^= byte;
    h *= prime;
  }

  for (var i = 0; i < count && i < messages.length; i++) {
    for (final c in messages[i].id.codeUnits) {
      add(c & 0xff);
      add(c >> 8);
    }
    add(0);
    for (final c in messages[i].content.codeUnits) {
      add(c & 0xff);
      add(c >> 8);
    }
    add(1);
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// 1 発言の内容ハッシュ (embedding が古くなったかの判定用)。
String contentHash(String text) => prefixHash([
  Message(id: '', role: MessageRole.user, alternates: [text]),
], 1);

// ---------------------------------------------------------------- 区切り

/// 次に要約する区切り [start, end)。まだ [chunkMessages] 件たまっていなければ null。
/// 直後に編集・再生成されやすい末尾 [reserveTail] 件は区切りに含めない。
(int, int)? planNextChunk({required int covered, required int total, required int chunkMessages, int reserveTail = 2}) {
  final end = covered + chunkMessages;
  if (chunkMessages <= 0 || end > total - reserveTail) return null;
  return (covered, end);
}

/// 次の自動整理 (区切り) まであと何往復か。0 ならもう整理できる状態。
int turnsUntilNextChunk({required int covered, required int total, required int chunkMessages, int reserveTail = 2}) {
  final remaining = covered + chunkMessages + reserveTail - total;
  return remaining <= 0 ? 0 : (remaining + 1) ~/ 2;
}

/// あらすじに区切り要約を畳み込むか。未反映が [batch] 個たまったか、もう新しい区切りが無いとき。
bool shouldFoldSynopsis({required int unfolded, required bool hasMoreChunks, int batch = 5}) =>
    unfolded > 0 && (!hasMoreChunks || unfolded >= batch);

// ---------------------------------------------------------------- 巻き戻し

/// 現在の発言列と矛盾しない最新のチェックポイント。無ければ null (最初から作り直し)。
MemoryCheckpoint? latestValidCheckpoint(List<MemoryCheckpoint> checkpoints, List<Message> messages) {
  for (final cp in checkpoints.reversed) {
    if (cp.count <= messages.length && prefixHash(messages, cp.count) == cp.hash) return cp;
  }
  return null;
}

/// 記憶が現在の発言列と一致しているか確かめ、編集などで食い違っていれば巻き戻す。
/// ピン留めした項目は巻き戻しでも残す。巻き戻したら true。
bool reconcileMemory(SessionMemory memory, List<Message> messages) {
  final latest = memory.checkpoints.lastOrNull;
  if (latest == null && memory.coveredCount == 0) return false;
  if (latest != null &&
      latest.count == memory.coveredCount &&
      latest.count <= messages.length &&
      prefixHash(messages, latest.count) == latest.hash) {
    return false;
  }

  final valid = latestValidCheckpoint(memory.checkpoints, messages);
  final pinned = [
    for (final f in memory.facts)
      if (f.pinned) f.copy(),
  ];
  if (valid == null) {
    memory
      ..facts.clear()
      ..synopsis = ''
      ..chunks.clear()
      ..foldedChunks = 0
      ..checkpoints.clear();
  } else {
    memory
      ..facts.clear()
      ..facts.addAll([for (final f in valid.facts) f.copy()])
      ..synopsis = valid.synopsis
      ..foldedChunks = valid.foldedChunks;
    memory.chunks.removeRange(min(valid.chunkCount, memory.chunks.length), memory.chunks.length);
    memory.checkpoints.removeWhere((c) => c.count > valid.count);
  }
  for (final p in pinned) {
    memory.facts.removeWhere((f) => f.id == p.id);
    memory.facts.add(p);
  }
  return true;
}

/// 分岐先 (発言列 [branchMessages]) に引き継ぐ記憶。分岐点より後の内容は含めない。
SessionMemory memoryForBranch(SessionMemory source, List<Message> branchMessages) {
  final memory = source.copy()..lastError = null;
  memory.checkpoints.removeWhere((c) => c.count > branchMessages.length);
  reconcileMemory(memory, branchMessages);
  return memory;
}

MemoryCheckpoint makeCheckpoint(SessionMemory memory, List<Message> messages) => MemoryCheckpoint(
  count: memory.coveredCount,
  hash: prefixHash(messages, memory.coveredCount),
  facts: [for (final f in memory.facts) f.copy()],
  synopsis: memory.synopsis,
  chunkCount: memory.chunks.length,
  foldedChunks: memory.foldedChunks,
);

// ---------------------------------------------------------------- 重要メモ

final _factLine = RegExp(r'^\s*(?:[-・*•]|\d+[.)．])\s*(?:\[\s*(?:重要度\s*[:：]?\s*)?([1-3])\s*\]\s*)?(.+?)\s*$');
final _bareImportance = RegExp(r'^\s*\[\s*(?:重要度\s*[:：]?\s*)?([1-3])\s*\]\s*(.+?)\s*$');

/// LLM の出力 (`- [重要度3] 内容` の箇条書き) を項目に分解する。
List<MemoryItem> parseFacts(String text) {
  final items = <MemoryItem>[];
  final seen = <String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('```')) continue;
    final m = _factLine.firstMatch(line) ?? _bareImportance.firstMatch(line);
    if (m == null) continue;
    final body = m.group(2)!.trim();
    if (body.isEmpty || !seen.add(body)) continue;
    items.add(MemoryItem(text: body, importance: int.tryParse(m.group(1) ?? '') ?? 2));
  }
  return items;
}

String formatFacts(List<MemoryItem> items, {bool withImportance = true}) =>
    [for (final f in items) withImportance ? '- [重要度${f.importance}] ${f.text}' : '- ${f.text}'].join('\n');

int totalChars(List<MemoryItem> items) => items.fold(0, (sum, f) => sum + f.text.length);

/// 自動整理の結果 [updated] (ピン留め以外) と、ピン留め項目 [pinned] を合わせた新しいメモ。
/// 同じ文面の項目は ID を引き継ぐ。出力が空なら (LLM の失敗とみなして) 以前のメモを残す。
List<MemoryItem> mergeFacts({required List<MemoryItem> previous, required List<MemoryItem> updated}) {
  final pinned = [
    for (final f in previous)
      if (f.pinned) f,
  ];
  if (updated.isEmpty) return [for (final f in previous) f];
  final byText = {for (final f in previous) f.text: f};
  final pinnedTexts = {for (final f in pinned) f.text};
  return [
    ...pinned,
    for (final f in updated)
      if (!pinnedTexts.contains(f.text)) MemoryItem(id: byText[f.text]?.id, text: f.text, importance: f.importance),
  ];
}

/// 合計 [maxChars] 字に収まるよう、ピン留め以外を重要度の低い順 (同じなら後ろの項目から) に削る。
List<MemoryItem> enforceFactsLimit(List<MemoryItem> items, int maxChars) {
  var total = totalChars(items);
  if (total <= maxChars) return items;
  final removable =
      [
        for (var i = 0; i < items.length; i++)
          if (!items[i].pinned) i,
      ]..sort((a, b) {
        final byImportance = items[a].importance.compareTo(items[b].importance);
        return byImportance != 0 ? byImportance : b.compareTo(a);
      });
  final removed = <int>{};
  for (final i in removable) {
    if (total <= maxChars) break;
    removed.add(i);
    total -= items[i].text.length;
  }
  return [
    for (var i = 0; i < items.length; i++)
      if (!removed.contains(i)) items[i],
  ];
}

// ---------------------------------------------------------------- 直近の範囲

/// プロンプトにそのまま入れる直近の発言の開始位置。
/// 直近 [recentTurns] 往復に加えて、まだ要約されていない発言 ([covered] 以降) も必ず含める。
/// ただし合計が [maxChars] を超えるなら古い方から削る (最低 2 件は残す)。
int recentWindowStart({
  required List<int> lengths,
  required int recentTurns,
  required int covered,
  required int maxChars,
}) {
  final n = lengths.length;
  var start = max(0, n - recentTurns * 2);
  start = min(start, max(0, min(covered, n)));
  var total = 0;
  for (var i = start; i < n; i++) {
    total += lengths[i];
  }
  while (total > maxChars && n - start > 2) {
    total -= lengths[start];
    start++;
  }
  return start;
}

// ---------------------------------------------------------------- 検索

/// 正規化して int8 に量子化する (端末に保存するサイズを 1/4 に)。
Int8List quantize(List<double> v) {
  var norm = 0.0;
  for (final x in v) {
    norm += x * x;
  }
  norm = sqrt(norm);
  final out = Int8List(v.length);
  if (norm == 0) return out;
  for (var i = 0; i < v.length; i++) {
    out[i] = (v[i] / norm * 127).round().clamp(-127, 127);
  }
  return out;
}

double cosine(Int8List a, Int8List b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0, na = 0, nb = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (sqrt(na) * sqrt(nb));
}

/// 直近の発言 ([query]) と意味が近い過去の発言を選ぶ。
/// [candidates] は発言の位置 → embedding。[before] 以降 (直近の範囲) は除外し、
/// [minScore] 未満は捨て、上位 [topK] 件を時系列順で返す。
List<int> selectRetrieved({
  required Int8List query,
  required Map<int, Int8List> candidates,
  required int before,
  required int topK,
  double minScore = 0.45,
}) {
  final scored = <(int, double)>[
    for (final e in candidates.entries)
      if (e.key < before) (e.key, cosine(query, e.value)),
  ].where((s) => s.$2 >= minScore).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final s in scored.take(topK)) s.$1]..sort();
}

// ---------------------------------------------------------------- 要約・抽出のプロンプト

String transcript(List<Message> messages, String Function(Message) nameOf, {int maxCharsPerMessage = 1200}) => [
  for (final m in messages)
    if (m.content.trim().isNotEmpty)
      '${nameOf(m)}: ${m.content.length > maxCharsPerMessage ? '${m.content.substring(0, maxCharsPerMessage)}…' : m.content}',
].join('\n');

List<ChatTurn> chunkSummaryPrompt(String log) => [
  const ChatTurn(
    'system',
    'あなたは物語の記録係です。ロールプレイの会話ログの一部を読み、出来事・関係の変化・約束・重要な台詞を'
        '時系列で 300 字程度に要約してください。推測や感想は書かず、要約本文だけを出力してください。',
  ),
  ChatTurn('user', '会話ログ:\n$log'),
];

List<ChatTurn> synopsisFoldPrompt({
  required String synopsis,
  required List<String> newSummaries,
  required int maxChars,
}) => [
  ChatTurn(
    'system',
    'あなたは物語の記録係です。「これまでのあらすじ」に「その後の出来事」を統合し、物語全体のあらすじを '
        '$maxChars 字以内で書き直してください。古い出来事は簡潔に、最近の出来事ほど具体的に。'
        'あらすじ本文だけを出力してください。',
  ),
  ChatTurn(
    'user',
    '## これまでのあらすじ\n${synopsis.trim().isEmpty ? '(なし。物語の始まり)' : synopsis.trim()}\n\n'
        '## その後の出来事\n${newSummaries.join('\n\n')}',
  ),
];

List<ChatTurn> factsUpdatePrompt({required List<MemoryItem> current, required String log, required int maxChars}) {
  final pinned = [
    for (final f in current)
      if (f.pinned) f,
  ];
  final editable = [
    for (final f in current)
      if (!f.pinned) f,
  ];
  return [
    ChatTurn(
      'system',
      'あなたは物語の記憶係です。「現在のメモ」と「新しい会話」から、今後の会話で忘れたら困る事実'
          '(名前・呼び方・関係性・約束・出来事・好み・持ち物・居場所など) をまとめた最新のメモを作ってください。\n'
          'ルール:\n'
          '- 追記するだけでなく、重複は 1 つに統合し、矛盾する内容は新しい会話の方を正とする。\n'
          '- その場限りの描写や雑談は含めない。\n'
          '- 各行を `- [重要度N] 内容` の形式で書く (N は 1〜3、3 が最重要)。\n'
          '- 合計 $maxChars 字以内。収まらないときは重要度の低いものから短くまとめるか削る。\n'
          '- 「固定メモ」はすでに保持されているので出力しない。固定メモと矛盾する内容も書かない。\n'
          '- メモの箇条書きだけを出力する。',
    ),
    ChatTurn(
      'user',
      '## 固定メモ\n${pinned.isEmpty ? '(なし)' : formatFacts(pinned, withImportance: false)}\n\n'
          '## 現在のメモ\n${editable.isEmpty ? '(なし)' : formatFacts(editable)}\n\n'
          '## 新しい会話\n$log',
    ),
  ];
}

List<ChatTurn> factsCompressPrompt({required List<MemoryItem> items, required int maxChars}) => [
  ChatTurn(
    'system',
    'あなたは物語の記憶係です。次のメモを合計 $maxChars 字以内に圧縮してください。重要度の低いものから'
        '短くまとめるか削り、重要度 3 の事実はできるだけ残してください。'
        '各行を `- [重要度N] 内容` の形式で、箇条書きだけを出力してください。',
  ),
  ChatTurn(
    'user',
    formatFacts([
      for (final f in items)
        if (!f.pinned) f,
    ]),
  ),
];
