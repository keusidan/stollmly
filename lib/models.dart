import 'dart:math';

import 'memory/memory_models.dart';

final _random = Random.secure();

String newId() {
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final r = List.generate(6, (_) => _random.nextInt(36).toRadixString(36)).join();
  return '$t$r';
}

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// ナレーションの視点。
enum NarrationPov {
  first('一人称', 'キャラクター自身の一人称視点で描写する'),
  second('二人称', 'ユーザーを「あなた」と呼ぶ二人称視点で描写する'),
  third('三人称', '三人称の地の文で情景と行動を描写する');

  const NarrationPov(this.label, this.instruction);
  final String label;
  final String instruction;
}

/// 物語のテンポ。
enum StoryTempo {
  slow('ゆっくり', '一つの場面を丁寧に描写し、展開は急がない'),
  normal('ふつう', '会話と描写のバランスを取り、自然な速さで物語を進める'),
  fast('はやい', '展開を積極的に進め、場面転換や新しい出来事を起こしてよい');

  const StoryTempo(this.label, this.instruction);
  final String label;
  final String instruction;
}

/// キャラクターがどれくらい心を開いているか。
enum Openness {
  guarded('警戒', 'ユーザーにはまだ心を開いておらず、距離を取った態度をとる'),
  neutral('ふつう', 'ユーザーとは普通の距離感で接する'),
  open('親密', 'ユーザーにはすでに心を開いており、親しげに接する');

  const Openness(this.label, this.instruction);
  final String label;
  final String instruction;
}

/// 応答の長さ。
enum ReplyLength {
  short('短め', '応答は 1〜3 文程度に短くまとめる', 256),
  medium('ふつう', '応答は 1〜2 段落程度にする', 512),
  long('長め', '描写を豊かにし、3 段落程度まで書いてよい', 1024);

  const ReplyLength(this.label, this.instruction, this.maxTokens);
  final String label;
  final String instruction;
  final int maxTokens;
}

/// ロアブロック: キーワードが会話に出たときだけプロンプトに差し込まれる設定。
class LoreEntry {
  LoreEntry({String? id, this.title = '', this.keywords = const [], this.content = '', this.alwaysOn = false})
    : id = id ?? newId();

  final String id;
  String title;
  List<String> keywords;
  String content;
  bool alwaysOn;

  bool matches(String text) {
    if (alwaysOn) return true;
    final lower = text.toLowerCase();
    return keywords.any((k) => k.trim().isNotEmpty && lower.contains(k.trim().toLowerCase()));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'keywords': keywords,
    'content': content,
    'alwaysOn': alwaysOn,
  };

  factory LoreEntry.fromJson(Map<String, dynamic> j) => LoreEntry(
    id: j['id'] as String?,
    title: j['title'] as String? ?? '',
    keywords: (j['keywords'] as List<dynamic>? ?? const []).cast<String>(),
    content: j['content'] as String? ?? '',
    alwaysOn: j['alwaysOn'] as bool? ?? false,
  );
}

class Character {
  Character({
    String? id,
    this.name = '',
    this.tagline = '',
    this.description = '',
    this.prompt = '',
    this.intro = '',
    this.exampleDialogue = '',
    this.tags = const [],
    this.lore = const [],
    this.avatar = '',
    this.colorValue = 0xFF7C4DFF,
    this.pov = NarrationPov.third,
    this.tempo = StoryTempo.normal,
    this.openness = Openness.neutral,
    this.replyLength = ReplyLength.medium,
    this.favorite = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? newId(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;

  /// 一覧に出る一言 (肩書き)。
  String tagline;

  /// ユーザー向けの紹介文。モデルには渡さない。
  String description;

  /// モデル向けのキャラクター設定 (プロンプト)。
  String prompt;

  /// 会話開始時に最初に表示される場面。
  String intro;

  /// 口調の例。「{{user}}: …」「{{char}}: …」形式。
  String exampleDialogue;
  List<String> tags;
  List<LoreEntry> lore;

  /// 絵文字 1 文字など。空なら名前の頭文字。
  String avatar;
  int colorValue;
  NarrationPov pov;
  StoryTempo tempo;
  Openness openness;
  ReplyLength replyLength;
  bool favorite;
  final DateTime createdAt;
  DateTime updatedAt;

  Character copy() => Character.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'tagline': tagline,
    'description': description,
    'prompt': prompt,
    'intro': intro,
    'exampleDialogue': exampleDialogue,
    'tags': tags,
    'lore': [for (final l in lore) l.toJson()],
    'avatar': avatar,
    'color': colorValue,
    'pov': pov.name,
    'tempo': tempo.name,
    'openness': openness.name,
    'replyLength': replyLength.name,
    'favorite': favorite,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Character.fromJson(Map<String, dynamic> j) => Character(
    id: j['id'] as String?,
    name: j['name'] as String? ?? '',
    tagline: j['tagline'] as String? ?? '',
    description: j['description'] as String? ?? '',
    prompt: j['prompt'] as String? ?? '',
    intro: j['intro'] as String? ?? '',
    exampleDialogue: j['exampleDialogue'] as String? ?? '',
    tags: (j['tags'] as List<dynamic>? ?? const []).cast<String>(),
    lore: [for (final l in j['lore'] as List<dynamic>? ?? const []) LoreEntry.fromJson(l as Map<String, dynamic>)],
    avatar: j['avatar'] as String? ?? '',
    colorValue: j['color'] as int? ?? 0xFF7C4DFF,
    pov: _enumByName(NarrationPov.values, j['pov'], NarrationPov.third),
    tempo: _enumByName(StoryTempo.values, j['tempo'], StoryTempo.normal),
    openness: _enumByName(Openness.values, j['openness'], Openness.neutral),
    replyLength: _enumByName(ReplyLength.values, j['replyLength'], ReplyLength.medium),
    favorite: j['favorite'] as bool? ?? false,
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
  );

  /// 共有用 (クリップボード経由のインポート/エクスポート)。ID は含めない。
  Map<String, dynamic> toShareJson() {
    final j = toJson()
      ..remove('id')
      ..remove('favorite')
      ..remove('createdAt')
      ..remove('updatedAt');
    return {'stollmly': 'character', 'version': 1, ...j};
  }
}

/// トークプロフィール (ユーザー側のペルソナ)。
class Persona {
  Persona({String? id, this.name = '', this.description = ''}) : id = id ?? newId();

  final String id;
  String name;
  String description;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'description': description};

  factory Persona.fromJson(Map<String, dynamic> j) =>
      Persona(id: j['id'] as String?, name: j['name'] as String? ?? '', description: j['description'] as String? ?? '');
}

enum MessageRole { user, character }

/// 1 発言。キャラクターの発言は再生成で複数の候補 (alternates) を持ち、スワイプで切り替える。
class Message {
  Message({
    String? id,
    required this.role,
    this.characterId,
    List<String>? alternates,
    this.selected = 0,
    DateTime? createdAt,
  }) : id = id ?? newId(),
       alternates = alternates ?? [''],
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final MessageRole role;
  final String? characterId;
  final List<String> alternates;
  int selected;
  final DateTime createdAt;

  String get content => alternates[selected.clamp(0, alternates.length - 1)];
  set content(String value) => alternates[selected.clamp(0, alternates.length - 1)] = value;

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.name,
    if (characterId != null) 'characterId': characterId,
    'alternates': alternates,
    'selected': selected,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Message.fromJson(Map<String, dynamic> j) {
    final alternates = (j['alternates'] as List<dynamic>? ?? const ['']).cast<String>().toList();
    return Message(
      id: j['id'] as String?,
      role: _enumByName(MessageRole.values, j['role'], MessageRole.user),
      characterId: j['characterId'] as String?,
      alternates: alternates.isEmpty ? [''] : alternates,
      selected: j['selected'] as int? ?? 0,
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    );
  }

  Message copy() => Message.fromJson(toJson());
}

/// 1 つのトークルーム。キャラクターが 2 人以上ならグループチャット。
class ChatSession {
  ChatSession({
    String? id,
    required this.characterIds,
    this.title = '',
    this.personaId,
    this.userNote = '',
    List<Message>? messages,
    SessionMemory? memory,
    this.parentSessionId,
    this.parentTitle,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? newId(),
       messages = messages ?? [],
       memory = memory ?? SessionMemory(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final List<String> characterIds;
  String title;
  String? personaId;

  /// ユーザーノート: 毎回プロンプトに差し込まれる備忘録。
  String userNote;
  final List<Message> messages;

  /// 長期記憶 (重要メモ・あらすじ・区切り要約)。
  final SessionMemory memory;

  /// 分岐して作られたトークなら、分岐元のトーク。
  final String? parentSessionId;
  final String? parentTitle;
  final DateTime createdAt;
  DateTime updatedAt;

  bool get isGroup => characterIds.length > 1;

  Map<String, dynamic> toJson() => {
    'id': id,
    'characterIds': characterIds,
    'title': title,
    if (personaId != null) 'personaId': personaId,
    'userNote': userNote,
    'messages': [for (final m in messages) m.toJson()],
    'memory': memory.toJson(),
    'parentSessionId': ?parentSessionId,
    'parentTitle': ?parentTitle,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ChatSession.fromJson(Map<String, dynamic> j) => ChatSession(
    id: j['id'] as String?,
    characterIds: (j['characterIds'] as List<dynamic>? ?? const []).cast<String>().toList(),
    title: j['title'] as String? ?? '',
    personaId: j['personaId'] as String?,
    userNote: j['userNote'] as String? ?? '',
    messages: [
      for (final m in j['messages'] as List<dynamic>? ?? const []) Message.fromJson(m as Map<String, dynamic>),
    ],
    memory: j['memory'] is Map<String, dynamic> ? SessionMemory.fromJson(j['memory'] as Map<String, dynamic>) : null,
    parentSessionId: j['parentSessionId'] as String?,
    parentTitle: j['parentTitle'] as String?,
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
  );
}

/// 接続したことのある LLM ホスト。IP が変わっても [id] で同一ホストと判定する。
class SavedHost {
  SavedHost({required this.id, required this.name, required this.address, required this.port, this.token});

  final String id;
  String name;
  String address;
  int port;
  String? token;

  Uri get baseUri => Uri(scheme: 'http', host: address, port: port);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'port': port,
    if (token != null) 'token': token,
  };

  factory SavedHost.fromJson(Map<String, dynamic> j) => SavedHost(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    address: j['address'] as String,
    port: j['port'] as int? ?? 47320,
    token: j['token'] as String?,
  );
}

class AppSettings {
  AppSettings({
    this.hosts = const [],
    this.activeHostId,
    this.model,
    this.temperature = 0.9,
    this.contextChars = 16000,
    this.themeMode = 'system',
    this.defaultPersonaId,
    this.checkUpdatesOnStart = true,
    this.updateFromAllBranches = false,
    this.skippedVersion,
    this.outputFormat,
    this.memoryEnabled = true,
    this.memoryInterval = 20,
    this.memoryFactsMaxChars = 3000,
    this.memorySynopsisChars = 1000,
    this.recentTurns = 6,
    this.retrievalEnabled = true,
    this.retrievalTopK = 3,
    this.embedModel = 'bge-m3',
  });

  List<SavedHost> hosts;
  String? activeHostId;
  String? model;
  double temperature;

  /// 履歴をどこまでプロンプトに含めるか (文字数)。
  int contextChars;
  String themeMode;
  String? defaultPersonaId;
  bool checkUpdatesOnStart;

  /// main 以外のブランチのビルドもアップデート対象にする。
  bool updateFromAllBranches;
  String? skippedVersion;

  /// ユーザーが編集した出力フォーマット。null なら同梱の既定を使う。
  String? outputFormat;

  // 長期記憶
  bool memoryEnabled;

  /// 何往復ごとに要約・重要メモの整理をするか。
  int memoryInterval;
  int memoryFactsMaxChars;
  int memorySynopsisChars;

  /// プロンプトにそのまま入れる直近の往復数。
  int recentTurns;
  bool retrievalEnabled;
  int retrievalTopK;
  String embedModel;

  MemoryConfig get memoryConfig => MemoryConfig(
    enabled: memoryEnabled,
    interval: memoryInterval,
    factsMaxChars: memoryFactsMaxChars,
    synopsisChars: memorySynopsisChars,
    recentTurns: recentTurns,
    retrievalEnabled: retrievalEnabled,
    retrievalTopK: retrievalTopK,
    embedModel: embedModel,
  );

  SavedHost? get activeHost {
    for (final h in hosts) {
      if (h.id == activeHostId) return h;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'hosts': [for (final h in hosts) h.toJson()],
    'activeHostId': activeHostId,
    'model': model,
    'temperature': temperature,
    'contextChars': contextChars,
    'themeMode': themeMode,
    'defaultPersonaId': defaultPersonaId,
    'checkUpdatesOnStart': checkUpdatesOnStart,
    'updateFromAllBranches': updateFromAllBranches,
    'skippedVersion': skippedVersion,
    'outputFormat': outputFormat,
    'memoryEnabled': memoryEnabled,
    'memoryInterval': memoryInterval,
    'memoryFactsMaxChars': memoryFactsMaxChars,
    'memorySynopsisChars': memorySynopsisChars,
    'recentTurns': recentTurns,
    'retrievalEnabled': retrievalEnabled,
    'retrievalTopK': retrievalTopK,
    'embedModel': embedModel,
  };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
    hosts: [for (final h in j['hosts'] as List<dynamic>? ?? const []) SavedHost.fromJson(h as Map<String, dynamic>)],
    activeHostId: j['activeHostId'] as String?,
    model: j['model'] as String?,
    temperature: (j['temperature'] as num?)?.toDouble() ?? 0.9,
    contextChars: j['contextChars'] as int? ?? 16000,
    themeMode: j['themeMode'] as String? ?? 'system',
    defaultPersonaId: j['defaultPersonaId'] as String?,
    checkUpdatesOnStart: j['checkUpdatesOnStart'] as bool? ?? true,
    updateFromAllBranches: j['updateFromAllBranches'] as bool? ?? false,
    skippedVersion: j['skippedVersion'] as String?,
    outputFormat: j['outputFormat'] as String?,
    memoryEnabled: j['memoryEnabled'] as bool? ?? true,
    memoryInterval: j['memoryInterval'] as int? ?? 20,
    memoryFactsMaxChars: j['memoryFactsMaxChars'] as int? ?? 3000,
    memorySynopsisChars: j['memorySynopsisChars'] as int? ?? 1000,
    recentTurns: j['recentTurns'] as int? ?? 6,
    retrievalEnabled: j['retrievalEnabled'] as bool? ?? true,
    retrievalTopK: j['retrievalTopK'] as int? ?? 3,
    embedModel: j['embedModel'] as String? ?? 'bge-m3',
  );
}
