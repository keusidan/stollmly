import '../models.dart';

/// 重要メモの 1 項目。
class MemoryItem {
  MemoryItem({String? id, required this.text, this.importance = 2, this.pinned = false}) : id = id ?? newId();

  final String id;
  String text;

  /// 1 (低) 〜 3 (高)。上限を超えたときは低いものから削る。
  int importance;

  /// ピン留めした項目は自動整理で消さない・書き換えない。
  bool pinned;

  MemoryItem copy() => MemoryItem(id: id, text: text, importance: importance, pinned: pinned);

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'importance': importance, 'pinned': pinned};

  factory MemoryItem.fromJson(Map<String, dynamic> j) => MemoryItem(
    id: j['id'] as String?,
    text: j['text'] as String? ?? '',
    importance: (j['importance'] as int? ?? 2).clamp(1, 3),
    pinned: j['pinned'] as bool? ?? false,
  );
}

/// 区切り (messages[start, end)) ごとの要約。
class ChunkSummary {
  ChunkSummary({required this.start, required this.end, required this.summary});

  final int start;
  final int end;
  String summary;

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'summary': summary};

  factory ChunkSummary.fromJson(Map<String, dynamic> j) =>
      ChunkSummary(start: j['start'] as int, end: j['end'] as int, summary: j['summary'] as String? ?? '');
}

/// ある時点 (先頭 [count] 件の発言を処理し終えた時点) の記憶のスナップショット。
/// [hash] は先頭 [count] 件の発言の内容ハッシュ。編集・削除で一致しなくなったら、
/// それより後の記憶は信用せずこのスナップショットまで巻き戻す。
class MemoryCheckpoint {
  MemoryCheckpoint({
    required this.count,
    required this.hash,
    required this.facts,
    required this.synopsis,
    required this.chunkCount,
    required this.foldedChunks,
  });

  final int count;
  final String hash;
  final List<MemoryItem> facts;
  final String synopsis;
  final int chunkCount;
  final int foldedChunks;

  Map<String, dynamic> toJson() => {
    'count': count,
    'hash': hash,
    'facts': [for (final f in facts) f.toJson()],
    'synopsis': synopsis,
    'chunkCount': chunkCount,
    'foldedChunks': foldedChunks,
  };

  factory MemoryCheckpoint.fromJson(Map<String, dynamic> j) => MemoryCheckpoint(
    count: j['count'] as int,
    hash: j['hash'] as String,
    facts: [for (final f in j['facts'] as List<dynamic>? ?? const []) MemoryItem.fromJson(f as Map<String, dynamic>)],
    synopsis: j['synopsis'] as String? ?? '',
    chunkCount: j['chunkCount'] as int? ?? 0,
    foldedChunks: j['foldedChunks'] as int? ?? 0,
  );
}

/// トークごとの長期記憶。
class SessionMemory {
  SessionMemory({
    List<MemoryItem>? facts,
    this.synopsis = '',
    List<ChunkSummary>? chunks,
    this.foldedChunks = 0,
    List<MemoryCheckpoint>? checkpoints,
    this.lastError,
  }) : facts = facts ?? [],
       chunks = chunks ?? [],
       checkpoints = checkpoints ?? [];

  /// 重要メモ (毎回プロンプトに入る)。
  final List<MemoryItem> facts;

  /// 全体のあらすじ (毎回プロンプトに入る)。
  String synopsis;

  /// 区切りごとの要約。末尾の end までの発言が要約・事実抽出済み。
  final List<ChunkSummary> chunks;

  /// あらすじに畳み込み済みの区切り数。
  int foldedChunks;

  final List<MemoryCheckpoint> checkpoints;

  /// 直近の自動整理で起きたエラー (画面表示用)。
  String? lastError;

  /// ユーザーが記憶を手で編集するたびに増える (保存しない)。
  /// 自動整理中に編集されたら、その結果で上書きせずにやり直すために使う。
  int editVersion = 0;

  /// 先頭から何件の発言を処理し終えたか。
  int get coveredCount => chunks.isEmpty ? 0 : chunks.last.end;

  bool get isEmpty => facts.isEmpty && synopsis.trim().isEmpty && chunks.isEmpty;

  SessionMemory copy() => SessionMemory.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'facts': [for (final f in facts) f.toJson()],
    'synopsis': synopsis,
    'chunks': [for (final c in chunks) c.toJson()],
    'foldedChunks': foldedChunks,
    'checkpoints': [for (final c in checkpoints) c.toJson()],
    if (lastError != null) 'lastError': lastError,
  };

  factory SessionMemory.fromJson(Map<String, dynamic> j) => SessionMemory(
    facts: [for (final f in j['facts'] as List<dynamic>? ?? const []) MemoryItem.fromJson(f as Map<String, dynamic>)],
    synopsis: j['synopsis'] as String? ?? '',
    chunks: [
      for (final c in j['chunks'] as List<dynamic>? ?? const []) ChunkSummary.fromJson(c as Map<String, dynamic>),
    ],
    foldedChunks: j['foldedChunks'] as int? ?? 0,
    checkpoints: [
      for (final c in j['checkpoints'] as List<dynamic>? ?? const [])
        MemoryCheckpoint.fromJson(c as Map<String, dynamic>),
    ],
    lastError: j['lastError'] as String?,
  );
}

/// 長期記憶の設定 (AppSettings から作る)。
class MemoryConfig {
  const MemoryConfig({
    this.enabled = true,
    this.interval = 20,
    this.factsMaxChars = 3000,
    this.synopsisChars = 1000,
    this.recentTurns = 6,
    this.retrievalEnabled = true,
    this.retrievalTopK = 3,
    this.embedModel = 'bge-m3',
  });

  final bool enabled;

  /// 何往復ごとに要約・事実抽出するか。
  final int interval;
  final int factsMaxChars;
  final int synopsisChars;

  /// プロンプトにそのまま入れる直近の往復数。
  final int recentTurns;
  final bool retrievalEnabled;
  final int retrievalTopK;
  final String embedModel;

  /// 1 区切りの発言数 (1 往復 = 2 発言)。
  int get chunkMessages => interval * 2;
}
