import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 1 発言の embedding。[hash] は埋め込んだ時点の本文ハッシュ (編集されたら作り直す)。
class StoredEmbedding {
  StoredEmbedding({required this.hash, required this.model, required this.vector});

  final String hash;
  final String model;
  final Int8List vector;
}

/// トークごとに、発言 ID → embedding を保持する。
abstract class EmbeddingStore {
  Future<Map<String, StoredEmbedding>> load(String sessionId);
  void put(String sessionId, String messageId, StoredEmbedding e);

  /// [keep] に含まれない発言の embedding を消す (削除・巻き戻しされた発言の掃除)。
  void retain(String sessionId, Set<String> keep);

  /// 分岐: [from] のうち [messageIds] の分を [to] に複製する。
  Future<void> copy(String from, String to, Set<String> messageIds);
  Future<void> delete(String sessionId);
}

class InMemoryEmbeddingStore implements EmbeddingStore {
  final Map<String, Map<String, StoredEmbedding>> data = {};

  @override
  Future<Map<String, StoredEmbedding>> load(String sessionId) async => data.putIfAbsent(sessionId, () => {});

  @override
  void put(String sessionId, String messageId, StoredEmbedding e) =>
      data.putIfAbsent(sessionId, () => {})[messageId] = e;

  @override
  void retain(String sessionId, Set<String> keep) => data[sessionId]?.removeWhere((id, _) => !keep.contains(id));

  @override
  Future<void> copy(String from, String to, Set<String> messageIds) async {
    final src = await load(from);
    final dst = await load(to);
    for (final id in messageIds) {
      final e = src[id];
      if (e != null) dst[id] = e;
    }
  }

  @override
  Future<void> delete(String sessionId) async => data.remove(sessionId);
}

/// 端末に保存する実装。トークごとに 1 ファイル (JSON、ベクトルは int8 を base64)。
class FileEmbeddingStore extends InMemoryEmbeddingStore {
  FileEmbeddingStore(this.directory);

  final Directory directory;
  final Map<String, Timer> _pending = {};

  File _file(String sessionId) => File('${directory.path}${Platform.pathSeparator}$sessionId.json');

  @override
  Future<Map<String, StoredEmbedding>> load(String sessionId) async {
    final cached = data[sessionId];
    if (cached != null) return cached;
    final map = <String, StoredEmbedding>{};
    try {
      final file = _file(sessionId);
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final e in json.entries) {
          final v = e.value as Map<String, dynamic>;
          map[e.key] = StoredEmbedding(
            hash: v['h'] as String,
            model: v['m'] as String,
            vector: Int8List.fromList(base64Decode(v['v'] as String)),
          );
        }
      }
    } catch (_) {
      // 壊れていたら作り直す (検索用のキャッシュなので失っても困らない)
    }
    return data[sessionId] = map;
  }

  void _scheduleSave(String sessionId) {
    _pending[sessionId]?.cancel();
    _pending[sessionId] = Timer(const Duration(seconds: 2), () => _save(sessionId));
  }

  Future<void> _save(String sessionId) async {
    _pending.remove(sessionId);
    final map = data[sessionId];
    if (map == null) return;
    await directory.create(recursive: true);
    final json = {
      for (final e in map.entries)
        e.key: {'h': e.value.hash, 'm': e.value.model, 'v': base64Encode(Uint8List.sublistView(e.value.vector))},
    };
    final tmp = File('${_file(sessionId).path}.tmp');
    await tmp.writeAsString(jsonEncode(json));
    await tmp.rename(_file(sessionId).path);
  }

  @override
  void put(String sessionId, String messageId, StoredEmbedding e) {
    super.put(sessionId, messageId, e);
    _scheduleSave(sessionId);
  }

  @override
  void retain(String sessionId, Set<String> keep) {
    final before = data[sessionId]?.length ?? 0;
    super.retain(sessionId, keep);
    if ((data[sessionId]?.length ?? 0) != before) _scheduleSave(sessionId);
  }

  @override
  Future<void> copy(String from, String to, Set<String> messageIds) async {
    await super.copy(from, to, messageIds);
    _scheduleSave(to);
  }

  @override
  Future<void> delete(String sessionId) async {
    _pending.remove(sessionId)?.cancel();
    await super.delete(sessionId);
    try {
      await _file(sessionId).delete();
    } catch (_) {}
  }
}
