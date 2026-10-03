// stollmly-host: LAN 上のスマホ/PC から、このマシンで動いている LLM に接続するための専用ブリッジ。
//
// - TCP 47320 : HTTP API (/api/v1/...)。チャットは NDJSON でストリーミング返却する。
// - UDP 47321 : 発見用。"STOLLMLY_DISCOVER" を受け取ったらホスト情報を JSON で返す。
// - 上流 LLM は OpenAI 互換 API (/v1/chat/completions) を話すものなら何でもよい。
//   未指定なら Ollama(11434) / llama.cpp(8080) / LM Studio(1234) / vLLM(8000) を自動検出する。
//
// LLM 本体は localhost に閉じたままにでき、LAN にはこのブリッジだけを公開する。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const protocolVersion = 1;
const hostVersion = '0.2.2';
const defaultHttpPort = 47320;
const discoveryPort = 47321;
const discoveryMagic = 'STOLLMLY_DISCOVER';

const _candidateUpstreams = <String, String>{
  'Ollama': 'http://127.0.0.1:11434/v1',
  'llama.cpp': 'http://127.0.0.1:8080/v1',
  'LM Studio': 'http://127.0.0.1:1234/v1',
  'vLLM': 'http://127.0.0.1:8000/v1',
};

Future<void> main(List<String> args) async {
  final Config config;
  try {
    config = Config.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}\n');
    stderr.writeln(Config.usage);
    exitCode = 64;
    return;
  }
  if (config.showHelp) {
    stdout.writeln(Config.usage);
    return;
  }

  final upstream = config.upstream ?? await _detectUpstream(config.upstreamApiKey);
  if (upstream == null) {
    stderr.writeln('上流の LLM サーバーが見つかりませんでした。');
    stderr.writeln('Ollama などを起動するか、--upstream http://127.0.0.1:PORT/v1 を指定してください。');
    exitCode = 69;
    return;
  }

  final identity = await HostIdentity.load();
  final host = Host(config: config, upstream: Upstream(upstream, config.upstreamApiKey), identity: identity);
  await host.start();

  ProcessSignal.sigint.watch().listen((_) => host.stop().then((_) => exit(0)));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => host.stop().then((_) => exit(0)));
  }
}

Future<String?> _detectUpstream(String? apiKey) async {
  for (final entry in _candidateUpstreams.entries) {
    final upstream = Upstream(entry.value, apiKey);
    try {
      await upstream.listModels().timeout(const Duration(seconds: 2));
      _log('上流を自動検出: ${entry.key} (${entry.value})');
      return entry.value;
    } catch (_) {
      // 次の候補へ
    }
  }
  return null;
}

class Config {
  Config({
    required this.port,
    required this.name,
    required this.upstream,
    required this.upstreamApiKey,
    required this.reasoningEffort,
    required this.token,
    required this.allowPublic,
    required this.showHelp,
  });

  final int port;
  final String name;
  final String? upstream;
  final String? upstreamApiKey;

  /// チャットの上流リクエストに付ける reasoning_effort。null なら付けない (モデル既定)。
  /// 思考するモデルは思考中 content が空のため、none にしないと返事が遅れたり max_tokens で空になる。
  final String? reasoningEffort;

  /// 設定するとアプリ側で接続時にトークン入力が必要になる。
  final String? token;

  /// false (既定) の場合、プライベート IP 以外からの接続を拒否する。
  final bool allowPublic;
  final bool showHelp;

  static const usage =
      '''
stollmly-host $hostVersion — LAN 上の stollmly アプリにローカル LLM を公開するブリッジ

使い方: stollmly-host [オプション]

  --upstream URL     OpenAI 互換 API のベース URL (例: http://127.0.0.1:11434/v1)
                     省略時は Ollama / llama.cpp / LM Studio / vLLM を自動検出
  --upstream-key KEY 上流 API に Bearer で渡すキー (必要な場合のみ)
  --reasoning-effort none|low|medium|high
                     思考するモデルの思考量。none で思考を止める (省略時はモデル既定)
  --port N           HTTP ポート (既定: $defaultHttpPort)。発見用 UDP は常に $discoveryPort
  --name NAME        アプリに表示されるホスト名 (既定: マシンのホスト名)
  --token TOKEN      接続に必要なトークン。省略時はトークン不要 (LAN 内限定)
  --allow-public     プライベート IP 以外からの接続も許可する (非推奨)
  -h, --help         このヘルプを表示

環境変数 STOLLMLY_UPSTREAM / STOLLMLY_UPSTREAM_KEY / STOLLMLY_REASONING_EFFORT /
STOLLMLY_PORT / STOLLMLY_NAME / STOLLMLY_TOKEN でも指定できます (引数が優先)。''';

  static Config parse(List<String> args) {
    final env = Platform.environment;
    final values = <String, String>{};
    final flags = <String>{};
    const valued = {'--upstream', '--upstream-key', '--reasoning-effort', '--port', '--name', '--token'};
    const boolean = {'--allow-public', '--help', '-h'};

    for (var i = 0; i < args.length; i++) {
      var arg = args[i];
      String? inline;
      final eq = arg.indexOf('=');
      if (arg.startsWith('--') && eq > 0) {
        inline = arg.substring(eq + 1);
        arg = arg.substring(0, eq);
      }
      if (valued.contains(arg)) {
        final value = inline ?? (i + 1 < args.length ? args[++i] : null);
        if (value == null) throw FormatException('$arg には値が必要です');
        values[arg] = value;
      } else if (boolean.contains(arg)) {
        flags.add(arg);
      } else {
        throw FormatException('不明なオプション: $arg');
      }
    }

    final portText = values['--port'] ?? env['STOLLMLY_PORT'];
    final port = portText == null ? defaultHttpPort : int.tryParse(portText);
    if (port == null || port <= 0 || port > 65535) {
      throw FormatException('ポート番号が不正です: $portText');
    }
    if (port == discoveryPort) {
      throw FormatException('ポート $discoveryPort は発見用に予約されています');
    }

    String? nonEmpty(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();
    var upstream = nonEmpty(values['--upstream'] ?? env['STOLLMLY_UPSTREAM']);
    if (upstream != null && upstream.endsWith('/')) {
      upstream = upstream.substring(0, upstream.length - 1);
    }

    final reasoningEffort = nonEmpty(values['--reasoning-effort'] ?? env['STOLLMLY_REASONING_EFFORT']);
    if (reasoningEffort != null && !const {'none', 'low', 'medium', 'high'}.contains(reasoningEffort)) {
      throw FormatException('--reasoning-effort は none / low / medium / high のいずれかです: $reasoningEffort');
    }

    return Config(
      port: port,
      name: nonEmpty(values['--name'] ?? env['STOLLMLY_NAME']) ?? Platform.localHostname,
      upstream: upstream,
      upstreamApiKey: nonEmpty(values['--upstream-key'] ?? env['STOLLMLY_UPSTREAM_KEY']),
      reasoningEffort: reasoningEffort,
      token: nonEmpty(values['--token'] ?? env['STOLLMLY_TOKEN']),
      allowPublic: flags.contains('--allow-public'),
      showHelp: flags.contains('--help') || flags.contains('-h'),
    );
  }
}

/// IP が DHCP で変わってもアプリが同じホストだと分かるよう、永続 ID を保存する。
class HostIdentity {
  HostIdentity(this.id);

  final String id;

  static Future<HostIdentity> load() async {
    final file = File('${_configDir()}${Platform.pathSeparator}host.json');
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final id = json['id'];
      if (id is String && id.isNotEmpty) return HostIdentity(id);
    } catch (_) {
      // 初回起動 or 壊れている → 作り直す
    }
    final random = Random.secure();
    final id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'id': id}));
    } catch (e) {
      _log('警告: ホスト ID を保存できませんでした ($e)。再起動ごとに ID が変わります。');
    }
    return HostIdentity(id);
  }

  static String _configDir() {
    final env = Platform.environment;
    if (Platform.isWindows) return '${env['APPDATA'] ?? '.'}\\stollmly-host';
    if (Platform.isMacOS) return '${env['HOME']}/Library/Application Support/stollmly-host';
    final xdg = env['XDG_CONFIG_HOME'];
    return '${(xdg == null || xdg.isEmpty) ? '${env['HOME']}/.config' : xdg}/stollmly-host';
  }
}

/// OpenAI 互換 API のクライアント。
class Upstream {
  Upstream(this.baseUrl, this.apiKey);

  final String baseUrl;
  final String? apiKey;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  Future<HttpClientRequest> _open(String method, String path) async {
    final request = await _client.openUrl(method, Uri.parse('$baseUrl$path'));
    if (apiKey != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    return request;
  }

  Future<List<String>> listModels() async {
    final request = await _open('GET', '/models');
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode != 200) {
      throw HttpException('GET /models -> ${response.statusCode}: $body');
    }
    final data = (jsonDecode(body) as Map<String, dynamic>)['data'] as List<dynamic>? ?? const [];
    return [
      for (final m in data)
        if (m is Map && m['id'] is String) m['id'] as String,
    ]..sort();
  }

  /// OpenAI 互換の /embeddings を呼ぶ。入力と同じ順で返す。
  Future<List<List<num>>> embed(String model, List<String> inputs) async {
    final request = await _open('POST', '/embeddings');
    final bytes = utf8.encode(jsonEncode({'model': model, 'input': inputs}));
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode != 200) {
      throw HttpException('上流が embedding でエラーを返しました (${response.statusCode}): ${_upstreamError(body)}');
    }
    final data = (jsonDecode(body) as Map<String, dynamic>)['data'] as List<dynamic>? ?? const [];
    final sorted = [for (final d in data) d as Map<String, dynamic>]
      ..sort((a, b) => ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));
    return [for (final d in sorted) (d['embedding'] as List<dynamic>).cast<num>()];
  }

  /// SSE で受け取ったトークン片を順に流す。[cancel] が完了すると上流接続を切る。
  Stream<String> streamChat(Map<String, dynamic> body, Future<void> cancel) async* {
    final request = await _open('POST', '/chat/completions');
    // chunked 送信を受け付けない実装があるので Content-Length を明示する
    final bytes = utf8.encode(jsonEncode({...body, 'stream': true}));
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    if (response.statusCode != 200) {
      final text = await utf8.decodeStream(response);
      throw HttpException('上流がエラーを返しました (${response.statusCode}): ${_upstreamError(text)}');
    }
    // アプリ側が切断したら上流の生成も止める (GPU を無駄に回さない)
    unawaited(cancel.then((_) => request.abort()));

    final lines = response.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') return;
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(payload) as Map<String, dynamic>;
      } on FormatException {
        continue;
      }
      if (json['error'] != null) throw HttpException('上流エラー: ${json['error']}');
      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) continue;
      final delta = (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
      final content = delta?['content'];
      if (content is String && content.isNotEmpty) yield content;
    }
  }

  void close() => _client.close(force: true);
}

class Host {
  Host({required this.config, required this.upstream, required this.identity});

  final Config config;
  final Upstream upstream;
  final HostIdentity identity;
  HttpServer? _http;
  RawDatagramSocket? _udp;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.anyIPv4, config.port);
    _http!.listen(_handle, onError: (Object e) => _log('HTTP エラー: $e'));
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
      _udp!.listen(_onDatagram);
    } catch (e) {
      _log('警告: 発見用 UDP $discoveryPort を開けませんでした ($e)。アプリの IP スキャンでは見つかります。');
    }

    final addresses = await _lanAddresses();
    _log('stollmly-host $hostVersion 起動 — 名前: "${config.name}"');
    _log('上流 LLM: ${upstream.baseUrl}');
    if (config.reasoningEffort != null) _log('思考 (reasoning_effort): ${config.reasoningEffort}');
    for (final a in addresses) {
      _log('  アプリからの接続先: $a:${config.port}');
    }
    _log(config.token == null ? '認証: なし (プライベート IP からのみ受け付け)' : '認証: トークン必須');
    try {
      final models = await upstream.listModels();
      _log('利用可能なモデル: ${models.isEmpty ? '(なし)' : models.join(', ')}');
    } catch (e) {
      _log('警告: モデル一覧を取得できませんでした: $e');
    }
  }

  Future<void> stop() async {
    _log('停止します');
    _udp?.close();
    await _http?.close(force: true);
    upstream.close();
  }

  Map<String, dynamic> _info() => {
    'app': 'stollmly-host',
    'protocol': protocolVersion,
    'version': hostVersion,
    'id': identity.id,
    'name': config.name,
    'port': config.port,
    'auth': config.token != null,
    'features': ['chat', 'embed'],
    'os': Platform.operatingSystem,
  };

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _udp?.receive();
    if (datagram == null) return;
    if (!config.allowPublic && !isPrivateAddress(datagram.address)) return;
    final text = utf8.decode(datagram.data, allowMalformed: true).trim();
    if (!text.startsWith(discoveryMagic)) return;
    final reply = utf8.encode(jsonEncode(_info()));
    _udp?.send(reply, datagram.address, datagram.port);
  }

  Future<void> _handle(HttpRequest request) async {
    final remote = request.connectionInfo?.remoteAddress;
    final response = request.response;
    try {
      if (!config.allowPublic && (remote == null || !isPrivateAddress(remote))) {
        return await _json(response, HttpStatus.forbidden, {'error': 'LAN 外からの接続は許可されていません'});
      }
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/api/v1/info') {
        return await _json(response, HttpStatus.ok, _info());
      }
      if (!_authorized(request)) {
        return await _json(response, HttpStatus.unauthorized, {'error': 'トークンが違います'});
      }
      switch ((request.method, path)) {
        case ('GET', '/api/v1/models'):
          return await _json(response, HttpStatus.ok, {'models': await upstream.listModels()});
        case ('POST', '/api/v1/embed'):
          return await _embed(request);
        case ('POST', '/api/v1/chat'):
          return await _chat(request, remote);
        default:
          return await _json(response, HttpStatus.notFound, {'error': 'not found'});
      }
    } catch (e) {
      _log('${request.method} ${request.uri.path} 失敗: $e');
      try {
        await _json(response, HttpStatus.badGateway, {'error': _errorText(e)});
      } catch (_) {
        // ヘッダ送信済みなど。接続ごと捨てる
      }
    }
  }

  bool _authorized(HttpRequest request) {
    final token = config.token;
    if (token == null) return true;
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    return _constantTimeEquals(header, 'Bearer $token');
  }

  Future<void> _chat(HttpRequest request, InternetAddress? remote) async {
    final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    final messages = body['messages'];
    if (messages is! List || messages.isEmpty) {
      return _json(request.response, HttpStatus.badRequest, {'error': 'messages が必要です'});
    }
    final upstreamBody = <String, dynamic>{
      'model': body['model'],
      'messages': messages,
      for (final key in const ['temperature', 'top_p', 'max_tokens', 'stop', 'presence_penalty', 'frequency_penalty'])
        if (body[key] != null) key: body[key],
      if (config.reasoningEffort != null) 'reasoning_effort': config.reasoningEffort,
    };

    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..bufferOutput = false;

    final cancel = Completer<void>();
    unawaited(
      response.done.then((_) {}, onError: (_) {}).whenComplete(() {
        if (!cancel.isCompleted) cancel.complete();
      }),
    );

    final started = DateTime.now();
    var chars = 0;
    _log('chat 開始: ${remote?.address} model=${body['model']} messages=${messages.length}');
    try {
      await for (final delta in upstream.streamChat(upstreamBody, cancel.future)) {
        if (cancel.isCompleted) break;
        chars += delta.length;
        response.write('${jsonEncode({'delta': delta})}\n');
        await response.flush();
      }
      if (!cancel.isCompleted) response.write('${jsonEncode({'done': true})}\n');
    } catch (e) {
      _log('chat エラー: $e');
      if (!cancel.isCompleted) response.write('${jsonEncode({'error': _errorText(e)})}\n');
    } finally {
      if (!cancel.isCompleted) cancel.complete();
      await response.close().catchError((_) {});
      final ms = DateTime.now().difference(started).inMilliseconds;
      _log('chat 終了: $chars 文字 / ${ms}ms');
    }
  }

  Future<void> _embed(HttpRequest request) async {
    final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    final model = body['model'];
    final input = body['input'];
    if (model is! String || input is! List || input.isEmpty || input.any((x) => x is! String)) {
      return _json(request.response, HttpStatus.badRequest, {'error': 'model と input (文字列の配列) が必要です'});
    }
    try {
      final vectors = await upstream.embed(model, input.cast<String>());
      return await _json(request.response, HttpStatus.ok, {'model': model, 'embeddings': vectors});
    } catch (e) {
      _log('embed エラー: $e');
      return await _json(request.response, HttpStatus.badGateway, {'error': _errorText(e)});
    }
  }

  Future<void> _json(HttpResponse response, int status, Object body) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }
}

/// RFC 1918 / ループバック / リンクローカル / CGNAT (Tailscale 等) / IPv6 ULA を「LAN」とみなす。
bool isPrivateAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal) return true;
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  if (address.type == InternetAddressType.IPv6) {
    // IPv4-mapped (::ffff:a.b.c.d)
    final mapped = b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
    if (mapped) {
      return isPrivateAddress(InternetAddress.fromRawAddress(b.sublist(12)));
    }
    return (b[0] & 0xfe) == 0xfc;
  }
  return false;
}

Future<List<String>> _lanAddresses() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  return [
    for (final i in interfaces)
      for (final a in i.addresses)
        if (!a.isLoopback && isPrivateAddress(a)) '${a.address} (${i.name})',
  ];
}

bool _constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < min(x.length, y.length); i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

String _truncate(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

/// 上流のエラー本文から読める部分を取り出す。OpenAI 互換の `{"error":{"message":...}}` /
/// `{"error":"..."}` ならそのメッセージ、それ以外は本文の先頭。
String _upstreamError(String body) {
  try {
    final error = (jsonDecode(body) as Map<String, dynamic>)['error'];
    final message = error is Map ? error['message'] : error;
    if (message is String && message.isNotEmpty) return _truncate(message, 500);
  } catch (_) {}
  return _truncate(body, 500);
}

/// アプリに返すエラー文。HttpException の "HttpException: " 接頭辞は付けない。
String _errorText(Object e) => e is HttpException ? e.message : e.toString();

void _log(String message) {
  final now = DateTime.now().toIso8601String().substring(11, 19);
  stdout.writeln('[$now] $message');
}
