import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stollmly/models.dart';
import 'package:stollmly/net/tts_client.dart';

void main() {
  group('normalizeTtsBaseUri', () {
    test('末尾のスラッシュや /v1・/v1/audio/speech を正規化する', () {
      expect(normalizeTtsBaseUri('https://example.trycloudflare.com').toString(), 'https://example.trycloudflare.com');
      expect(
        normalizeTtsBaseUri('  https://example.trycloudflare.com/  ').toString(),
        'https://example.trycloudflare.com',
      );
      expect(normalizeTtsBaseUri('http://127.0.0.1:8080/v1').toString(), 'http://127.0.0.1:8080');
      expect(normalizeTtsBaseUri('http://127.0.0.1:8080/v1/audio/speech/').toString(), 'http://127.0.0.1:8080');
    });

    test('不正なスキームや空文字は TtsException を投げる', () {
      expect(() => normalizeTtsBaseUri(''), throwsA(isA<TtsException>()));
      expect(() => normalizeTtsBaseUri('ftp://example.com'), throwsA(isA<TtsException>()));
      expect(() => normalizeTtsBaseUri('not-a-url'), throwsA(isA<TtsException>()));
    });
  });

  group('prepareTtsText', () {
    test('dialogueOnly=true のとき *描写* を除き [囁き] などのタグと台詞を残す', () {
      const raw = '*そっと近づく。*\n[囁き] ねえ、聞こえてる？\n*微笑んで続ける*\n大丈夫だよ。';
      expect(prepareTtsText(raw, dialogueOnly: true), '[囁き] ねえ、聞こえてる？\n大丈夫だよ。');
    });

    test('閉じ忘れた * は行末までを地の文として除く', () {
      const raw = '*こちらを見る。\nこんにちは。';
      expect(prepareTtsText(raw, dialogueOnly: true), 'こんにちは。');
    });

    test('地の文しかない場合は全文から * を除いて返す', () {
      const raw = '*静かに頷く。*';
      expect(prepareTtsText(raw, dialogueOnly: true), '静かに頷く。');
    });

    test('dialogueOnly=false のとき * のみを取り除いて全文を返す', () {
      const raw = '*そっと近づく。*\nこんにちは。';
      expect(prepareTtsText(raw, dialogueOnly: false), 'そっと近づく。\nこんにちは。');
    });
  });

  group('AppSettings TTS serialization', () {
    test('TTS 設定を保存・復元でき、旧形式 JSON でも既定値にフォールバックする', () {
      final settings = AppSettings(
        ttsBaseUrl: 'https://abc.trycloudflare.com',
        ttsVoice: 'custom',
        ttsApiKey: 'secret',
        ttsSpeakDialogueOnly: false,
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.ttsBaseUrl, 'https://abc.trycloudflare.com');
      expect(restored.ttsVoice, 'custom');
      expect(restored.ttsApiKey, 'secret');
      expect(restored.ttsSpeakDialogueOnly, isFalse);

      final legacy = AppSettings.fromJson(const {});
      expect(legacy.ttsBaseUrl, '');
      expect(legacy.ttsVoice, 'none');
      expect(legacy.ttsApiKey, '');
      expect(legacy.ttsSpeakDialogueOnly, isTrue);
    });
  });

  group('TtsClient', () {
    test('checkHealth と synthesize がリクエスト仕様通りに動作する', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      Map<String, dynamic>? receivedBody;
      String? receivedAuth;

      server.listen((req) async {
        if (req.method == 'GET' && req.uri.path == '/health') {
          req.response
            ..statusCode = 200
            ..write('{"status":"ok"}');
          await req.response.close();
          return;
        }
        if (req.method == 'GET' && req.uri.path == '/v1/models') {
          req.response
            ..statusCode = 200
            ..write('{"data":[{"id":"drama-3"}]}');
          await req.response.close();
          return;
        }
        if (req.method == 'POST' && req.uri.path == '/v1/audio/speech') {
          receivedAuth = req.headers.value(HttpHeaders.authorizationHeader);
          final body = await utf8.decodeStream(req);
          receivedBody = jsonDecode(body) as Map<String, dynamic>;
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType('audio', 'wav')
            ..add(Uint8List.fromList([82, 73, 70, 70, 0, 0, 0, 0]));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final client = TtsClient('http://127.0.0.1:${server.port}/v1', apiKey: 'tok123');
      final health = await client.checkHealth();
      expect(health.models, ['drama-3']);

      final wav = await client.synthesize(input: 'テストです。', voice: '');
      expect(wav, isNotEmpty);
      expect(receivedAuth, 'Bearer tok123');
      expect(receivedBody, {'input': 'テストです。', 'voice': 'none', 'response_format': 'wav'});
    });

    test('HTTP エラー時に JSON の error.message を抽出して TtsException を投げる', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        req.response
          ..statusCode = 400
          ..headers.contentType = ContentType.json
          ..write('{"error":{"message":"unsupported parameter"}}');
        await req.response.close();
      });

      final client = TtsClient('http://127.0.0.1:${server.port}');
      await expectLater(
        client.synthesize(input: 'hello'),
        throwsA(isA<TtsException>().having((e) => e.message, 'message', contains('unsupported parameter'))),
      );
    });
  });
}
