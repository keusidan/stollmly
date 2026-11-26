import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class TtsException implements Exception {
  TtsException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TtsHealthResult {
  const TtsHealthResult({required this.models});

  final List<String> models;
}

/// 読み上げ用にメッセージを整形する。
///
/// [dialogueOnly] が true の場合は `*描写*`（閉じ忘れの行末まで含む）を除き、
/// `[囁き]` などのインラインタグは保持する。台詞が空になった場合は全文から `*` を
/// 除いたものを返す。
String prepareTtsText(String raw, {required bool dialogueOnly}) {
  final fullText = raw.replaceAll('*', '').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  if (!dialogueOnly) return fullText;

  final lines = raw.split('\n');
  final keptLines = <String>[];
  for (final line in lines) {
    final cleaned = _stripNarrationFromLine(line).trim();
    if (cleaned.isNotEmpty) keptLines.add(cleaned);
  }
  final dialogue = keptLines.join('\n').trim();
  return dialogue.isEmpty ? fullText : dialogue;
}

String _stripNarrationFromLine(String line) {
  final out = StringBuffer();
  var i = 0;
  while (i < line.length) {
    final start = line.indexOf('*', i);
    if (start < 0) {
      out.write(line.substring(i));
      break;
    }
    out.write(line.substring(i, start));
    final end = line.indexOf('*', start + 1);
    if (end < 0) {
      // 閉じ忘れた * は行末までを地の文とみなす
      break;
    }
    i = end + 1;
  }
  return out.toString().replaceAll(RegExp(r' {2,}'), ' ');
}

/// ユーザーが入力した TTS サーバー URL を正規化する。
///
/// 末尾の `/` や `/v1`、`/v1/audio/speech` を取り除き、ベース URI を返す。
Uri normalizeTtsBaseUri(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) {
    throw TtsException('TTS サーバーの URL が設定されていません。');
  }
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || (parsed.scheme != 'http' && parsed.scheme != 'https') || parsed.host.isEmpty) {
    throw TtsException('TTS サーバーの URL が正しくありません (http:// または https:// で始まる URL を入力してください)。');
  }
  var path = parsed.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.endsWith('/v1/audio/speech')) {
    path = path.substring(0, path.length - '/v1/audio/speech'.length);
  } else if (path.endsWith('/v1')) {
    path = path.substring(0, path.length - '/v1'.length);
  }
  return parsed.replace(path: path, query: null, fragment: null);
}

/// speech.cpp (`speech serve`) などの OpenAI 互換 Audio API クライアント。
class TtsClient {
  TtsClient(String baseUrl, {String? apiKey}) : baseUri = normalizeTtsBaseUri(baseUrl), apiKey = apiKey?.trim() ?? '';

  final Uri baseUri;
  final String apiKey;

  static final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15);

  Uri _endpoint(String path) {
    final basePath = baseUri.path;
    final joined = basePath.isEmpty ? path : '$basePath$path';
    return baseUri.replace(path: joined);
  }

  void _applyAuth(HttpClientRequest request) {
    if (apiKey.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
  }

  Future<TtsHealthResult> checkHealth() async {
    try {
      final healthReq = await _http.getUrl(_endpoint('/health')).timeout(const Duration(seconds: 10));
      _applyAuth(healthReq);
      final healthRes = await healthReq.close().timeout(const Duration(seconds: 10));
      final healthBody = await utf8.decodeStream(healthRes).timeout(const Duration(seconds: 10));
      if (healthRes.statusCode != 200) {
        throw TtsException(_extractErrorMessage(healthRes.statusCode, healthBody));
      }

      final models = <String>[];
      try {
        final modelsReq = await _http.getUrl(_endpoint('/v1/models')).timeout(const Duration(seconds: 10));
        _applyAuth(modelsReq);
        final modelsRes = await modelsReq.close().timeout(const Duration(seconds: 10));
        final modelsBody = await utf8.decodeStream(modelsRes).timeout(const Duration(seconds: 10));
        if (modelsRes.statusCode == 200) {
          final decoded = jsonDecode(modelsBody);
          if (decoded is Map<String, dynamic> && decoded['data'] is List) {
            for (final item in decoded['data'] as List<dynamic>) {
              if (item is Map<String, dynamic> && item['id'] is String) {
                models.add(item['id'] as String);
              }
            }
          }
        }
      } catch (_) {
        // /v1/models が無いサーバーでも /health が通れば成功とみなす
      }
      return TtsHealthResult(models: models);
    } on TtsException {
      rethrow;
    } on TimeoutException {
      throw TtsException('TTS サーバーへの接続がタイムアウトしました。URL とサーバーの起動状態を確認してください。');
    } on SocketException catch (e) {
      throw TtsException('TTS サーバーに接続できませんでした: ${e.message}');
    } catch (e) {
      throw TtsException('TTS サーバーの確認に失敗しました: $e');
    }
  }

  /// `POST /v1/audio/speech` で WAV バイト列を生成する。
  ///
  /// Drama 3 では `instructions` や `speed` などの未対応フィールドを送ると
  /// speech.cpp が 400 を返すため、`input` / `voice` / `response_format` のみを送る。
  Future<Uint8List> synthesize({required String input, String voice = 'none'}) async {
    final trimmedInput = input.trim();
    if (trimmedInput.isEmpty) {
      throw TtsException('読み上げるテキストが空です。');
    }
    final resolvedVoice = voice.trim().isEmpty ? 'none' : voice.trim();
    try {
      final request = await _http.postUrl(_endpoint('/v1/audio/speech')).timeout(const Duration(seconds: 15));
      _applyAuth(request);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'input': trimmedInput, 'voice': resolvedVoice, 'response_format': 'wav'}));
      final response = await request.close().timeout(const Duration(seconds: 120));
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 120))) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (response.statusCode != 200) {
        final body = utf8.decode(bytes, allowMalformed: true);
        throw TtsException(_extractErrorMessage(response.statusCode, body));
      }
      if (bytes.isEmpty) {
        throw TtsException('TTS サーバーから空の音声データが返されました。');
      }
      return bytes;
    } on TtsException {
      rethrow;
    } on TimeoutException {
      throw TtsException('音声生成がタイムアウトしました。テキストが長すぎるか、サーバーが混み合っています。');
    } on SocketException catch (e) {
      throw TtsException('TTS サーバーに接続できませんでした: ${e.message}');
    } catch (e) {
      throw TtsException('音声生成に失敗しました: $e');
    }
  }

  String _extractErrorMessage(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic> && error['message'] != null) {
          return 'TTS サーバーがエラーを返しました ($statusCode): ${error['message']}';
        }
        if (error is String && error.isNotEmpty) {
          return 'TTS サーバーがエラーを返しました ($statusCode): $error';
        }
        if (decoded['message'] != null) {
          return 'TTS サーバーがエラーを返しました ($statusCode): ${decoded['message']}';
        }
      }
    } catch (_) {}
    final trimmed = body.trim();
    if (trimmed.isNotEmpty) {
      return 'TTS サーバーがエラーを返しました ($statusCode): $trimmed';
    }
    return 'TTS サーバーがエラーを返しました ($statusCode)';
  }
}
