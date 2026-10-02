import 'dart:async';
import 'dart:typed_data';

import '../models.dart';
import '../net/host_client.dart';
import 'embedding_store.dart';
import 'memory_logic.dart';
import 'memory_models.dart';

/// 記憶の処理で使う LLM の窓口。アプリでは stollmly-host、テストでは偽物を渡す。
abstract class MemoryGateway {
  /// 応答全体を返す。チャットの生成が始まったら [MemoryCancelled] で中断される。
  Future<String> complete(List<ChatTurn> turns, {int maxTokens = 1024, double temperature = 0.3});

  /// 各入力の embedding。モデルが無いなどで使えなければ例外。
  Future<List<List<double>>> embed(String model, List<String> inputs);
}

/// チャットを優先するため、バックグラウンド処理を中断したことを表す。後で再開すればよい。
class MemoryCancelled implements Exception {
  const MemoryCancelled();
}

/// 要約・事実抽出・embedding 作成をバックグラウンドで行い、検索も受け持つ。
class MemoryService {
  MemoryService({required this.gateway, required this.store, required this.config, required this.onChanged});

  final MemoryGateway gateway;
  final EmbeddingStore store;
  final MemoryConfig Function() config;

  /// 記憶が変わったとき (保存と再描画のため) に呼ばれる。
  final void Function() onChanged;

  final Set<String> _running = {};
  final Set<String> _rerun = {};

  /// 検索 (embedding) が使えない理由。null なら使える。
  String? retrievalUnavailableReason;
  DateTime? _retrievalRetryAt;

  bool isRunning(String sessionId) => _running.contains(sessionId);

  bool get retrievalAvailable {
    if (!config().retrievalEnabled) return false;
    final retryAt = _retrievalRetryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return false;
    return true;
  }

  /// 検索を一時的に無効にする (10 分後にもう一度試す)。重要メモとあらすじは引き続き動く。
  void markRetrievalFailed(Object error) {
    retrievalUnavailableReason = error.toString();
    _retrievalRetryAt = DateTime.now().add(const Duration(minutes: 10));
    onChanged();
  }

  /// 接続し直したときなどに検索をもう一度試せるようにする。
  void resetRetrieval() {
    retrievalUnavailableReason = null;
    _retrievalRetryAt = null;
  }

  /// たまっている発言を処理する。すでに処理中なら終わったあとにもう一度走らせる。
  Future<void> process(ChatSession s, String Function(Message) nameOf) async {
    if (!config().enabled) return;
    if (!_running.add(s.id)) {
      _rerun.add(s.id);
      return;
    }
    onChanged();
    try {
      do {
        _rerun.remove(s.id);
        await _processOnce(s, nameOf);
      } while (_rerun.contains(s.id));
    } on MemoryCancelled {
      // チャットを優先して中断。次の機会に続きから処理する
    } catch (e) {
      s.memory.lastError = e.toString();
    } finally {
      _running.remove(s.id);
      onChanged();
    }
  }

  /// 重要メモ (ピン留め以外)・あらすじ・区切り要約を捨てて最初から作り直す。
  Future<void> rebuild(ChatSession s, String Function(Message) nameOf) async {
    final pinned = [
      for (final f in s.memory.facts)
        if (f.pinned) f,
    ];
    s.memory
      ..facts.clear()
      ..facts.addAll(pinned)
      ..synopsis = ''
      ..chunks.clear()
      ..foldedChunks = 0
      ..checkpoints.clear()
      ..lastError = null;
    onChanged();
    await process(s, nameOf);
  }

  Future<void> _processOnce(ChatSession s, String Function(Message) nameOf) async {
    final cfg = config();
    final mem = s.memory;
    if (reconcileMemory(mem, s.messages)) onChanged();

    if (retrievalAvailable) await _embedPending(s, nameOf);

    while (true) {
      if (reconcileMemory(mem, s.messages)) onChanged();
      final chunk = planNextChunk(
        covered: mem.coveredCount,
        total: s.messages.length,
        chunkMessages: cfg.chunkMessages,
      );
      if (chunk == null) break;
      final (start, end) = chunk;
      final expected = prefixHash(s.messages, end);
      final editVersion = mem.editVersion;
      final log = transcript(s.messages.sublist(start, end), nameOf);

      final summary = (await gateway.complete(chunkSummaryPrompt(log), maxTokens: 800)).trim();
      var facts = mergeFacts(
        previous: mem.facts,
        updated: parseFacts(
          await gateway.complete(
            factsUpdatePrompt(current: mem.facts, log: log, maxChars: cfg.factsMaxChars),
            maxTokens: 2500,
          ),
        ),
      );
      if (totalChars(facts) > cfg.factsMaxChars) {
        final compressed = parseFacts(
          await gateway.complete(factsCompressPrompt(items: facts, maxChars: cfg.factsMaxChars), maxTokens: 2500),
        );
        facts = enforceFactsLimit(mergeFacts(previous: facts, updated: compressed), cfg.factsMaxChars);
      }

      // LLM を待っている間に発言や記憶が編集されていたら、この結果は捨ててやり直す
      if (mem.coveredCount != start || mem.editVersion != editVersion || prefixHash(s.messages, end) != expected) {
        continue;
      }

      mem.facts
        ..clear()
        ..addAll(facts);
      mem.chunks.add(ChunkSummary(start: start, end: end, summary: summary));

      final hasMore = planNextChunk(covered: end, total: s.messages.length, chunkMessages: cfg.chunkMessages) != null;
      if (shouldFoldSynopsis(unfolded: mem.chunks.length - mem.foldedChunks, hasMoreChunks: hasMore)) {
        final synopsis = (await gateway.complete(
          synopsisFoldPrompt(
            synopsis: mem.synopsis,
            newSummaries: [for (final c in mem.chunks.skip(mem.foldedChunks)) c.summary],
            maxChars: cfg.synopsisChars,
          ),
          maxTokens: 2000,
        )).trim();
        if (synopsis.isNotEmpty && mem.editVersion == editVersion && prefixHash(s.messages, end) == expected) {
          mem
            ..synopsis = synopsis
            ..foldedChunks = mem.chunks.length;
        }
      }

      mem.checkpoints.add(makeCheckpoint(mem, s.messages));
      if (mem.checkpoints.length > 60) mem.checkpoints.removeAt(0);
      mem.lastError = null;
      onChanged();
    }
  }

  static String _embedText(Message m, String Function(Message) nameOf) {
    final text = '${nameOf(m)}: ${m.content}';
    return text.length > 1500 ? text.substring(0, 1500) : text;
  }

  Future<void> _embedPending(ChatSession s, String Function(Message) nameOf) async {
    final model = config().embedModel;
    final stored = await store.load(s.id);
    store.retain(s.id, {for (final m in s.messages) m.id});
    final pending = [
      for (final m in s.messages)
        if (m.content.trim().length >= 4 &&
            (stored[m.id]?.hash != contentHash(m.content) || stored[m.id]?.model != model))
          m,
    ];
    try {
      for (var i = 0; i < pending.length; i += 16) {
        final batch = pending.sublist(i, i + 16 > pending.length ? pending.length : i + 16);
        final vectors = await gateway.embed(model, [for (final m in batch) _embedText(m, nameOf)]);
        if (vectors.length != batch.length) throw StateError('embedding の件数が合いません');
        for (var j = 0; j < batch.length; j++) {
          store.put(
            s.id,
            batch[j].id,
            StoredEmbedding(hash: contentHash(batch[j].content), model: model, vector: quantize(vectors[j])),
          );
        }
      }
      retrievalUnavailableReason = null;
    } on MemoryCancelled {
      rethrow;
    } catch (e) {
      markRetrievalFailed(e);
    }
  }

  /// [history] の先頭 [before] 件 (直近の範囲より前) から、[query] に意味が近い発言を選ぶ。
  /// 使えないときや失敗したときは空 (チャットは止めない)。
  Future<List<Message>> retrieve(
    ChatSession s,
    List<Message> history, {
    required int before,
    required String query,
  }) async {
    final cfg = config();
    if (!cfg.enabled || !retrievalAvailable || before <= 0 || query.trim().isEmpty) return const [];
    try {
      final stored = await store.load(s.id);
      final candidates = <int, Int8List>{};
      for (var i = 0; i < before && i < history.length; i++) {
        final e = stored[history[i].id];
        if (e != null && e.model == cfg.embedModel && e.hash == contentHash(history[i].content)) {
          candidates[i] = e.vector;
        }
      }
      if (candidates.isEmpty) return const [];
      final q = await gateway.embed(cfg.embedModel, [query]).timeout(const Duration(seconds: 5));
      if (q.isEmpty) return const [];
      final picked = selectRetrieved(
        query: quantize(q.first),
        candidates: candidates,
        before: before,
        topK: cfg.retrievalTopK,
      );
      return [for (final i in picked) history[i]];
    } catch (e) {
      markRetrievalFailed(e);
      return const [];
    }
  }

  /// 分岐したトークに、分岐点までの記憶と embedding を引き継ぐ。
  Future<void> inheritForBranch(ChatSession source, ChatSession branch) async {
    final inherited = memoryForBranch(source.memory, branch.messages);
    branch.memory
      ..facts.addAll(inherited.facts)
      ..synopsis = inherited.synopsis
      ..chunks.addAll(inherited.chunks)
      ..foldedChunks = inherited.foldedChunks
      ..checkpoints.addAll(inherited.checkpoints);
    await store.copy(source.id, branch.id, {for (final m in branch.messages) m.id});
  }
}
