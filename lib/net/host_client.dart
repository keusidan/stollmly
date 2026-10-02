import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// stollmly-host のプロトコル定数。host/bin/stollmly_host.dart と揃えること。
const hostProtocolVersion = 1;
const defaultHostPort = 47320;
const discoveryPort = 47321;
const discoveryMagic = 'STOLLMLY_DISCOVER';

class HostInfo {
  HostInfo({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.version,
    required this.protocol,
    required this.authRequired,
    required this.os,
  });

  final String id;
  final String name;
  final String address;
  final int port;
  final String version;
  final int protocol;
  final bool authRequired;
  final String os;

  bool get compatible => protocol == hostProtocolVersion;

  static HostInfo? tryParse(Object? json, String address) {
    if (json is! Map<String, dynamic> || json['app'] != 'stollmly-host') return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    return HostInfo(
      id: id,
      name: json['name'] as String? ?? address,
      address: address,
      port: json['port'] as int? ?? defaultHostPort,
      version: json['version'] as String? ?? '?',
      protocol: json['protocol'] as int? ?? 0,
      authRequired: json['auth'] as bool? ?? false,
      os: json['os'] as String? ?? '',
    );
  }
}

class HostException implements Exception {
  HostException(this.message, {this.unauthorized = false});

  final String message;
  final bool unauthorized;

  @override
  String toString() => message;
}

class ChatTurn {
  const ChatTurn(this.role, this.content);

  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

/// LAN 上の stollmly-host と話すクライアント。
class HostClient {
  HostClient(this.baseUri, {this.token});

  final Uri baseUri;
  final String? token;

  static final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 15);

  /// スキャン用。存在しない IP への接続待ちを早く打ち切る。
  static final HttpClient _probeHttp = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 1200)
    ..idleTimeout = const Duration(seconds: 1);

  static Future<HostInfo?> probe(String address, int port, {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final uri = Uri(scheme: 'http', host: address, port: port, path: '/api/v1/info');
      final request = await _probeHttp.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await utf8.decodeStream(response).timeout(timeout);
      return HostInfo.tryParse(jsonDecode(body), address);
    } catch (_) {
      return null;
    }
  }

  Future<HttpClientRequest> _open(String method, String path) async {
    final request = await _http.openUrl(method, baseUri.replace(path: path));
    if (token != null && token!.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    return request;
  }

  Future<void> _throwFor(HttpClientResponse response) async {
    final body = await utf8.decodeStream(response);
    String message = body;
    try {
      message = (jsonDecode(body) as Map<String, dynamic>)['error']?.toString() ?? body;
    } catch (_) {}
    throw HostException(
      'ホストがエラーを返しました (${response.statusCode}): $message',
      unauthorized: response.statusCode == HttpStatus.unauthorized,
    );
  }

  Future<List<String>> models() async {
    final request = await _open('GET', '/api/v1/models');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) await _throwFor(response);
    final json = jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
    return (json['models'] as List<dynamic>? ?? const []).cast<String>();
  }

  /// トークン片を順に流す。購読をキャンセルすると接続を切り、ホスト側の生成も止まる。
  Stream<String> chat({
    required String? model,
    required List<ChatTurn> messages,
    double? temperature,
    int? maxTokens,
    List<String>? stop,
  }) {
    late final StreamController<String> controller;
    HttpClientRequest? request;
    StreamSubscription<String>? sub;

    Future<void> run() async {
      try {
        request = await _open('POST', '/api/v1/chat');
        final bytes = utf8.encode(
          jsonEncode({
            'model': model,
            'messages': [for (final m in messages) m.toJson()],
            'temperature': ?temperature,
            'max_tokens': ?maxTokens,
            if (stop != null && stop.isNotEmpty) 'stop': stop,
          }),
        );
        request!.headers.contentType = ContentType.json;
        request!.contentLength = bytes.length;
        request!.add(bytes);
        final response = await request!.close();
        if (response.statusCode != 200) await _throwFor(response);
        sub = response
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                if (line.trim().isEmpty) return;
                final Map<String, dynamic> json;
                try {
                  json = jsonDecode(line) as Map<String, dynamic>;
                } on FormatException {
                  return;
                }
                final delta = json['delta'];
                if (delta is String) controller.add(delta);
                final error = json['error'];
                if (error != null) controller.addError(HostException(error.toString()));
              },
              onError: (Object e) {
                if (!controller.isClosed) controller.addError(HostException('接続が切れました: $e'));
              },
              onDone: () => controller.close(),
              cancelOnError: false,
            );
      } on HostException catch (e) {
        controller.addError(e);
        await controller.close();
      } catch (e) {
        controller.addError(HostException('ホストに接続できません: $e'));
        await controller.close();
      }
    }

    controller = StreamController<String>(
      onListen: run,
      onCancel: () async {
        await sub?.cancel();
        request?.abort();
      },
    );
    return controller.stream;
  }
}
