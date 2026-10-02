import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// アプリデータを 1 つの JSON ファイルに保存する。書き込みはデバウンスし、tmp → rename で原子的に置き換える。
class JsonStore {
  JsonStore._(this._file);

  final File _file;
  Timer? _debounce;
  Future<void> _pending = Future.value();

  static Future<JsonStore> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return JsonStore._(File('${dir.path}${Platform.pathSeparator}stollmly_data.json'));
  }

  String get path => _file.path;

  Future<Map<String, dynamic>?> load() async {
    try {
      if (!await _file.exists()) return null;
      return jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // 壊れていたら退避して空から始める (データを黙って消さない)
      try {
        await _file.rename('${_file.path}.broken-${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {}
      return null;
    }
  }

  void scheduleSave(Map<String, dynamic> Function() snapshot) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _write(snapshot()));
  }

  Future<void> flush(Map<String, dynamic> Function() snapshot) async {
    _debounce?.cancel();
    await _write(snapshot());
  }

  Future<void> _write(Map<String, dynamic> data) {
    _pending = _pending
        .then((_) async {
          final tmp = File('${_file.path}.tmp');
          await tmp.writeAsString(jsonEncode(data), flush: true);
          await tmp.rename(_file.path);
        })
        .catchError((Object _) {});
    return _pending;
  }
}
