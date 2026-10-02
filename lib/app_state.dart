import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'net/discovery.dart';
import 'net/host_client.dart';
import 'prompt.dart';
import 'sample_data.dart';
import 'storage.dart';
import 'update/updater.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

class AppState extends ChangeNotifier {
  AppState._(this._store);

  final JsonStore _store;

  final List<Character> characters = [];
  final List<Persona> personas = [];
  final List<ChatSession> sessions = [];
  AppSettings settings = AppSettings();

  ConnectionStatus connection = ConnectionStatus.disconnected;
  String? connectionError;
  List<String> models = [];
  HostClient? _client;

  ReleaseInfo? availableUpdate;

  /// 同梱の出力フォーマット (assets/prompts/output_format.md)。
  String defaultOutputFormat = '';

  /// 実際に使う出力フォーマット。ユーザーが編集していればそちらを優先。
  String get outputFormat => settings.outputFormat ?? defaultOutputFormat;

  /// 生成中のセッション ID → 購読
  final Map<String, StreamSubscription<String>> _generating = {};

  static Future<AppState> load() async {
    final store = await JsonStore.open();
    final state = AppState._(store);
    state.defaultOutputFormat = await rootBundle.loadString(outputFormatAsset);
    final data = await store.load();
    if (data == null) {
      state.characters.addAll(sampleCharacters());
      state.personas.add(Persona(name: 'あなた', description: ''));
      state.settings.defaultPersonaId = state.personas.first.id;
      state._save();
    } else {
      state._restore(data);
    }
    return state;
  }

  void _restore(Map<String, dynamic> data) {
    characters.addAll([
      for (final c in data['characters'] as List<dynamic>? ?? const []) Character.fromJson(c as Map<String, dynamic>),
    ]);
    personas.addAll([
      for (final p in data['personas'] as List<dynamic>? ?? const []) Persona.fromJson(p as Map<String, dynamic>),
    ]);
    sessions.addAll([
      for (final s in data['sessions'] as List<dynamic>? ?? const []) ChatSession.fromJson(s as Map<String, dynamic>),
    ]);
    settings = AppSettings.fromJson(data['settings'] as Map<String, dynamic>? ?? const {});
  }

  Map<String, dynamic> _snapshot() => {
    'version': 1,
    'characters': [for (final c in characters) c.toJson()],
    'personas': [for (final p in personas) p.toJson()],
    'sessions': [for (final s in sessions) s.toJson()],
    'settings': settings.toJson(),
  };

  void _save() => _store.scheduleSave(_snapshot);

  Future<void> flush() => _store.flush(_snapshot);

  String get dataPath => _store.path;

  /// 変更を保存して再描画する。UI 側でモデルを直接書き換えたあとに呼ぶ。
  void commit() {
    _save();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 起動時処理

  Future<void> startup() async {
    unawaited(reconnect());
    if (settings.checkUpdatesOnStart) unawaited(checkForUpdate(silent: true));
  }

  // ---------------------------------------------------------------- キャラクター

  Character? characterById(String? id) {
    for (final c in characters) {
      if (c.id == id) return c;
    }
    return null;
  }

  void upsertCharacter(Character c) {
    c.updatedAt = DateTime.now();
    final i = characters.indexWhere((x) => x.id == c.id);
    if (i >= 0) {
      characters[i] = c;
    } else {
      characters.insert(0, c);
    }
    commit();
  }

  void deleteCharacter(Character c) {
    characters.removeWhere((x) => x.id == c.id);
    sessions.removeWhere((s) => s.characterIds.length == 1 && s.characterIds.first == c.id);
    for (final s in sessions) {
      s.characterIds.remove(c.id);
    }
    sessions.removeWhere((s) => s.characterIds.isEmpty);
    commit();
  }

  /// クリップボード等から貼り付けた JSON を取り込む。
  Character importCharacter(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic> || json['stollmly'] != 'character') {
      throw const FormatException('stollmly のキャラクターデータではありません');
    }
    final c = Character.fromJson({...json, 'id': newId()});
    upsertCharacter(c);
    return c;
  }

  List<String> get allTags {
    final counts = <String, int>{};
    for (final c in characters) {
      for (final t in c.tags) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    return counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  }

  // ---------------------------------------------------------------- トークプロフィール

  Persona? personaById(String? id) {
    for (final p in personas) {
      if (p.id == id) return p;
    }
    return null;
  }

  Persona? personaFor(ChatSession s) => personaById(s.personaId) ?? personaById(settings.defaultPersonaId);

  void upsertPersona(Persona p) {
    final i = personas.indexWhere((x) => x.id == p.id);
    if (i >= 0) {
      personas[i] = p;
    } else {
      personas.add(p);
    }
    commit();
  }

  void deletePersona(Persona p) {
    personas.removeWhere((x) => x.id == p.id);
    if (settings.defaultPersonaId == p.id) settings.defaultPersonaId = personas.firstOrNull?.id;
    for (final s in sessions) {
      if (s.personaId == p.id) s.personaId = null;
    }
    commit();
  }

  // ---------------------------------------------------------------- トーク

  List<ChatSession> get sessionsByRecent => [...sessions]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  ChatSession? latestSessionFor(Character c) {
    ChatSession? best;
    for (final s in sessions) {
      if (s.characterIds.length == 1 && s.characterIds.first == c.id) {
        if (best == null || s.updatedAt.isAfter(best.updatedAt)) best = s;
      }
    }
    return best;
  }

  ChatSession newSession(List<Character> cast) {
    final session = ChatSession(
      characterIds: [for (final c in cast) c.id],
      title: cast.map((c) => c.name).join('、'),
      personaId: settings.defaultPersonaId,
    );
    final persona = personaFor(session);
    for (final c in cast) {
      if (c.intro.trim().isEmpty) continue;
      final userName = (persona?.name.trim().isNotEmpty ?? false) ? persona!.name.trim() : 'ユーザー';
      final intro = c.intro.replaceAll('{{char}}', c.name).replaceAll('{{user}}', userName);
      session.messages.add(Message(role: MessageRole.character, characterId: c.id, alternates: [intro]));
    }
    sessions.add(session);
    commit();
    return session;
  }

  void deleteSession(ChatSession s) {
    stopGeneration(s);
    sessions.removeWhere((x) => x.id == s.id);
    commit();
  }

  /// [upTo] までの履歴をコピーして新しいトークに分岐する。
  ChatSession branchSession(ChatSession s, Message upTo) {
    final index = s.messages.indexWhere((m) => m.id == upTo.id);
    final branch = ChatSession(
      characterIds: [...s.characterIds],
      title: '${s.title} (分岐)',
      personaId: s.personaId,
      userNote: s.userNote,
      messages: [for (final m in s.messages.take(index + 1)) m.copy()],
    );
    sessions.add(branch);
    commit();
    return branch;
  }

  /// [from] 以降を削除 (巻き戻し)。
  void rewindTo(ChatSession s, Message from) {
    stopGeneration(s);
    final index = s.messages.indexWhere((m) => m.id == from.id);
    if (index < 0) return;
    s.messages.removeRange(index, s.messages.length);
    s.updatedAt = DateTime.now();
    commit();
  }

  bool isGenerating(ChatSession s) => _generating.containsKey(s.id);

  void stopGeneration(ChatSession s) {
    _generating.remove(s.id)?.cancel();
    notifyListeners();
  }

  /// グループチャットで次に話すキャラクター (直前に話していない人を順番に)。
  Character? nextSpeaker(ChatSession s) {
    final cast = s.characterIds.map(characterById).nonNulls.toList();
    if (cast.isEmpty) return null;
    if (cast.length == 1) return cast.first;
    final last = s.messages.lastWhere(
      (m) => m.role == MessageRole.character,
      orElse: () => Message(role: MessageRole.user),
    );
    final i = cast.indexWhere((c) => c.id == last.characterId);
    return cast[(i + 1) % cast.length];
  }

  Future<void> sendUserMessage(ChatSession s, String text, {Character? speaker}) async {
    if (text.trim().isNotEmpty) {
      s.messages.add(Message(role: MessageRole.user, alternates: [text.trim()]));
    }
    s.updatedAt = DateTime.now();
    commit();
    final who = speaker ?? nextSpeaker(s);
    if (who != null) await _generate(s, who, Message(role: MessageRole.character, characterId: who.id), isNew: true);
  }

  /// 最後のキャラクター発言を作り直す。古い候補はスワイプで戻れるよう残す。
  Future<void> regenerate(ChatSession s) async {
    final last = s.messages.lastOrNull;
    if (last == null || last.role != MessageRole.character) return;
    final speaker = characterById(last.characterId);
    if (speaker == null) return;
    last.alternates.add('');
    last.selected = last.alternates.length - 1;
    commit();
    await _generate(s, speaker, last, isNew: false);
  }

  /// 最後の発言の続きを書かせる。
  Future<void> continueLast(ChatSession s) async {
    final last = s.messages.lastOrNull;
    if (last == null || last.role != MessageRole.character) return;
    final speaker = characterById(last.characterId);
    if (speaker == null) return;
    await _generate(s, speaker, last, isNew: false, append: true);
  }

  Future<void> _generate(
    ChatSession s,
    Character speaker,
    Message target, {
    required bool isNew,
    bool append = false,
  }) async {
    final client = _client;
    if (client == null) {
      throw HostException('LLM ホストに接続されていません。設定 → 接続 からホストを選んでください。');
    }
    stopGeneration(s);

    final history = [...s.messages];
    if (!isNew) history.removeLast();
    final builder = PromptBuilder(
      session: s,
      characters: {for (final id in s.characterIds) id: ?characterById(id)},
      speaker: speaker,
      persona: personaFor(s),
      contextChars: settings.contextChars,
      outputFormat: outputFormat,
    );
    // append 時は末尾が assistant になり、PromptBuilder が「(続けてください)」を足す
    final turns = builder.build(append ? [...history, target] : history);

    if (isNew) s.messages.add(target);
    final prefix = append ? '${target.content}\n' : '';
    final buffer = StringBuffer();
    final completer = Completer<void>();
    var lastNotify = DateTime.now();

    final sub = client
        .chat(
          model: settings.model,
          messages: turns,
          temperature: settings.temperature,
          maxTokens: speaker.replyLength.maxTokens,
        )
        .listen(
          (delta) {
            buffer.write(delta);
            target.content = prefix + stripSpeakerPrefix(buffer.toString().trimLeft(), speaker.name);
            // 毎トークン再描画すると重いので 50ms 間引く
            final now = DateTime.now();
            if (now.difference(lastNotify).inMilliseconds > 50) {
              lastNotify = now;
              notifyListeners();
            }
          },
          onError: (Object e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );
    _generating[s.id] = sub;
    notifyListeners();

    try {
      await completer.future;
    } finally {
      if (_generating[s.id] == sub) _generating.remove(s.id);
      target.content = target.content.trimRight();
      if (target.content.isEmpty) {
        // 何も生成されなかったら空の候補を残さない
        if (target.alternates.length > 1) {
          target.alternates.removeAt(target.selected);
          target.selected = target.alternates.length - 1;
        } else if (isNew) {
          s.messages.remove(target);
        }
      }
      s.updatedAt = DateTime.now();
      commit();
    }
  }

  /// 返答候補を 3 つ作る (⚡ ボタン)。
  Future<List<String>> suggestReplies(ChatSession s) async {
    final client = _client;
    if (client == null) throw HostException('LLM ホストに接続されていません。');
    final speaker = nextSpeaker(s);
    if (speaker == null) return const [];
    final builder = PromptBuilder(
      session: s,
      characters: {for (final id in s.characterIds) id: ?characterById(id)},
      speaker: speaker,
      persona: personaFor(s),
      contextChars: settings.contextChars,
      outputFormat: outputFormat,
    );
    final text = await client
        .chat(model: settings.model, messages: builder.buildSuggestions(s.messages), temperature: 1.0, maxTokens: 300)
        .join();
    return PromptBuilder.parseSuggestions(text);
  }

  // ---------------------------------------------------------------- 接続

  SavedHost? get activeHost => settings.activeHost;

  Future<List<HostInfo>> discover({void Function(HostInfo)? onFound, void Function(double)? onProgress}) =>
      HostDiscovery.scan(onFound: onFound, onProgress: onProgress);

  /// 一覧から選んだホストに接続する (ワンタップ接続)。
  Future<void> connectTo(HostInfo info, {String? token}) async {
    final existing = settings.hosts.where((h) => h.id == info.id).firstOrNull;
    final host = existing ?? SavedHost(id: info.id, name: info.name, address: info.address, port: info.port);
    host
      ..name = info.name
      ..address = info.address
      ..port = info.port;
    if (token != null) host.token = token;
    if (existing == null) settings.hosts = [...settings.hosts, host];
    settings.activeHostId = host.id;
    commit();
    await _connect(host);
  }

  /// 手入力の IP アドレスで接続する。
  Future<HostInfo> probeManual(String address, int port) async {
    final info = await HostClient.probe(address.trim(), port);
    if (info == null) {
      throw HostException(
        '$address:$port に stollmly-host が見つかりません。'
        'ホスト側で stollmly-host が起動しているか、ファイアウォールを確認してください。',
      );
    }
    return info;
  }

  void forgetHost(SavedHost host) {
    settings.hosts = settings.hosts.where((h) => h.id != host.id).toList();
    if (settings.activeHostId == host.id) {
      settings.activeHostId = null;
      _client = null;
      connection = ConnectionStatus.disconnected;
      models = [];
    }
    commit();
  }

  /// 前回のホストに再接続。IP が変わっていたら LAN を探し直して同じ ID のホストを見つける。
  Future<void> reconnect() async {
    final host = settings.activeHost;
    if (host == null) return;
    connection = ConnectionStatus.connecting;
    notifyListeners();
    final info = await HostClient.probe(host.address, host.port);
    if (info != null && info.id == host.id) {
      await _connect(host);
      return;
    }
    final found = await HostDiscovery.scan();
    final match = found.where((h) => h.id == host.id).firstOrNull;
    if (match != null) {
      host
        ..address = match.address
        ..port = match.port;
      commit();
      await _connect(host);
    } else {
      connection = ConnectionStatus.error;
      connectionError = '「${host.name}」(${host.address}) が見つかりません。ホスト側で stollmly-host が起動しているか確認してください。';
      notifyListeners();
    }
  }

  Future<void> _connect(SavedHost host) async {
    connection = ConnectionStatus.connecting;
    connectionError = null;
    notifyListeners();
    final client = HostClient(host.baseUri, token: host.token);
    try {
      final list = await client.models();
      _client = client;
      models = list;
      if (settings.model == null || !list.contains(settings.model)) {
        settings.model = list.firstOrNull;
      }
      connection = ConnectionStatus.connected;
      commit();
    } catch (e) {
      _client = null;
      models = [];
      connection = ConnectionStatus.error;
      connectionError = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  void selectModel(String model) {
    settings.model = model;
    commit();
  }

  // ---------------------------------------------------------------- アップデート

  Future<ReleaseInfo?> checkForUpdate({bool silent = false}) async {
    try {
      final latest = await Updater.fetchLatest();
      final newer = latest != null && Updater.isNewer(latest.tag, appVersion);
      availableUpdate = newer ? latest : null;
      notifyListeners();
      return availableUpdate;
    } catch (e) {
      if (silent) return null;
      rethrow;
    }
  }

  @override
  void dispose() {
    for (final sub in _generating.values) {
      sub.cancel();
    }
    super.dispose();
  }
}
