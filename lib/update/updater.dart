import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// CI で `--dart-define=APP_VERSION=alpha-20261002T120000Z` のように埋め込まれる。
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// 更新を取りに行く GitHub リポジトリ (owner/name)。
const updateRepo = String.fromEnvironment('UPDATE_REPO', defaultValue: 'keusidan/stollmly');

const _tagPrefix = 'alpha-';

class ReleaseAsset {
  ReleaseAsset({required this.name, required this.url, required this.size});

  final String name;
  final Uri url;
  final int size;
}

class ReleaseInfo {
  ReleaseInfo({
    required this.tag,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.publishedAt,
    required this.assets,
  });

  final String tag;
  final String name;
  final String body;
  final Uri htmlUrl;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  ReleaseAsset? get assetForThisPlatform {
    final wanted = Updater.assetNameForPlatform;
    if (wanted == null) return null;
    for (final a in assets) {
      if (a.name == wanted) return a;
    }
    return null;
  }
}

enum InstallOutcome {
  /// インストーラーを起動した / 再起動して置き換える
  started,

  /// Android:「提供元不明のアプリ」の許可画面を開いた。許可後にもう一度実行してもらう
  needsPermission,

  /// 自動インストールできないのでブラウザでリリースページを開いた (iOS など)
  openedInBrowser,
}

class UpdateException implements Exception {
  UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class Updater {
  static const _installer = MethodChannel('stollmly/installer');
  static final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  /// このプラットフォーム向けのリリースアセット名。.github/workflows/release.yml と揃えること。
  static String? get assetNameForPlatform {
    if (Platform.isAndroid) return 'stollmly-android.apk';
    if (Platform.isWindows) return 'stollmly-windows-x64.zip';
    if (Platform.isLinux) return 'stollmly-linux-x64.tar.gz';
    if (Platform.isMacOS) return 'stollmly-macos.zip';
    if (Platform.isIOS) return 'stollmly-ios-unsigned.ipa';
    return null;
  }

  /// iOS は署名の都合でアプリ自身による置き換えができない。
  static bool get canSelfInstall => !Platform.isIOS;

  /// `alpha-YYYYMMDDTHHMMSSZ` は辞書順 = 時刻順なので文字列比較でよい。
  static bool isNewer(String tag, String current) {
    if (!tag.startsWith(_tagPrefix)) return false;
    if (!current.startsWith(_tagPrefix)) return true; // dev ビルドなど
    return tag.compareTo(current) > 0;
  }

  static Future<ReleaseInfo?> fetchLatest() async {
    final uri = Uri.https('api.github.com', '/repos/$updateRepo/releases', {'per_page': '20'});
    final request = await _http.getUrl(uri);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'stollmly-updater');
    final response = await request.close().timeout(const Duration(seconds: 20));
    final body = await utf8.decodeStream(response);
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw UpdateException('GitHub API のレート制限中です。しばらくしてから再試行してください。');
    }
    if (response.statusCode != 200) {
      throw UpdateException('リリース情報を取得できませんでした (${response.statusCode})');
    }
    final releases = <ReleaseInfo>[];
    for (final r in jsonDecode(body) as List<dynamic>) {
      final m = r as Map<String, dynamic>;
      final tag = m['tag_name'] as String? ?? '';
      if (m['draft'] == true || !tag.startsWith(_tagPrefix)) continue;
      releases.add(
        ReleaseInfo(
          tag: tag,
          name: m['name'] as String? ?? tag,
          body: m['body'] as String? ?? '',
          htmlUrl: Uri.parse(m['html_url'] as String),
          publishedAt: DateTime.tryParse(m['published_at'] as String? ?? ''),
          assets: [
            for (final a in m['assets'] as List<dynamic>? ?? const [])
              ReleaseAsset(
                name: (a as Map<String, dynamic>)['name'] as String,
                url: Uri.parse(a['browser_download_url'] as String),
                size: a['size'] as int? ?? 0,
              ),
          ],
        ),
      );
    }
    if (releases.isEmpty) return null;
    releases.sort((a, b) => b.tag.compareTo(a.tag));
    return releases.first;
  }

  static Future<File> download(ReleaseAsset asset, {void Function(double progress)? onProgress}) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');

    final request = await _http.getUrl(asset.url);
    request.headers.set(HttpHeaders.userAgentHeader, 'stollmly-updater');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw UpdateException('ダウンロードに失敗しました (${response.statusCode})');
    }
    final total = response.contentLength > 0 ? response.contentLength : asset.size;
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.close();
    }
    if (asset.size > 0 && received != asset.size) {
      throw UpdateException('ダウンロードが途中で切れました ($received / ${asset.size} bytes)');
    }
    return file;
  }

  /// ダウンロード済みのファイルでアプリを置き換える。
  /// デスクトップでは置き換えスクリプトを起動したあと [exitApp] が呼ばれ、スクリプトが再起動する。
  static Future<InstallOutcome> install(
    File file,
    ReleaseInfo release, {
    required Future<void> Function() exitApp,
  }) async {
    if (Platform.isAndroid) {
      final result = await _installer.invokeMethod<String>('installApk', {'path': file.path});
      return result == 'needs_permission' ? InstallOutcome.needsPermission : InstallOutcome.started;
    }
    if (Platform.isWindows) {
      await _runWindowsSwap(file);
    } else if (Platform.isLinux) {
      await _runLinuxSwap(file);
    } else if (Platform.isMacOS) {
      await _runMacSwap(file);
    } else {
      await launchUrl(release.htmlUrl, mode: LaunchMode.externalApplication);
      return InstallOutcome.openedInBrowser;
    }
    await exitApp();
    return InstallOutcome.started;
  }

  static Future<void> openReleasePage(ReleaseInfo release) =>
      launchUrl(release.htmlUrl, mode: LaunchMode.externalApplication);

  static Future<void> _ensureWritable(Directory dir) async {
    final probe = File('${dir.path}${Platform.pathSeparator}.stollmly-write-test');
    try {
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (_) {
      throw UpdateException(
        '${dir.path} に書き込めないため自動更新できません。'
        'ユーザーが書き込めるフォルダにアプリを置くか、リリースページから手動で更新してください。',
      );
    }
  }

  static String _sq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static Future<void> _startDetachedSh(String script) async {
    final dir = (await getTemporaryDirectory()).path;
    final file = File('$dir/stollmly-update.sh');
    await file.writeAsString(script);
    await Process.start('/bin/sh', [file.path], mode: ProcessStartMode.detached);
  }

  static Future<void> _runLinuxSwap(File archive) async {
    final installDir = File(Platform.resolvedExecutable).parent;
    await _ensureWritable(installDir);
    final staging = '${archive.parent.path}/staging';
    await _startDetachedSh('''
#!/bin/sh
set -e
while kill -0 $pid 2>/dev/null; do sleep 0.3; done
rm -rf ${_sq(staging)}
mkdir -p ${_sq(staging)}
tar -xzf ${_sq(archive.path)} -C ${_sq(staging)}
cp -a ${_sq(staging)}/. ${_sq(installDir.path)}/
rm -rf ${_sq(staging)} ${_sq(archive.path)}
nohup ${_sq(Platform.resolvedExecutable)} >/dev/null 2>&1 &
''');
  }

  static Future<void> _runMacSwap(File archive) async {
    // .../stollmly.app/Contents/MacOS/stollmly → .../stollmly.app
    final appDir = File(Platform.resolvedExecutable).parent.parent.parent;
    if (!appDir.path.endsWith('.app')) {
      throw UpdateException('アプリの場所を特定できませんでした: ${appDir.path}');
    }
    await _ensureWritable(appDir.parent);
    final staging = '${archive.parent.path}/staging';
    await _startDetachedSh('''
#!/bin/sh
set -e
while kill -0 $pid 2>/dev/null; do sleep 0.3; done
rm -rf ${_sq(staging)}
mkdir -p ${_sq(staging)}
ditto -x -k ${_sq(archive.path)} ${_sq(staging)}
NEW_APP=\$(find ${_sq(staging)} -maxdepth 1 -name '*.app' | head -n 1)
[ -n "\$NEW_APP" ]
rm -rf ${_sq(appDir.path)}
mv "\$NEW_APP" ${_sq(appDir.path)}
xattr -dr com.apple.quarantine ${_sq(appDir.path)} 2>/dev/null || true
rm -rf ${_sq(staging)} ${_sq(archive.path)}
open ${_sq(appDir.path)}
''');
  }

  static Future<void> _runWindowsSwap(File archive) async {
    final installDir = File(Platform.resolvedExecutable).parent;
    await _ensureWritable(installDir);
    String ps(String s) => "'${s.replaceAll("'", "''")}'";
    final staging = '${archive.parent.path}\\staging';
    final script = File('${archive.parent.path}\\stollmly-update.ps1');
    await script.writeAsString('''
\$ErrorActionPreference = 'Stop'
Wait-Process -Id $pid -Timeout 60 -ErrorAction SilentlyContinue
if (Test-Path ${ps(staging)}) { Remove-Item ${ps(staging)} -Recurse -Force }
Expand-Archive -LiteralPath ${ps(archive.path)} -DestinationPath ${ps(staging)} -Force
Copy-Item -Path (Join-Path ${ps(staging)} '*') -Destination ${ps(installDir.path)} -Recurse -Force
Remove-Item ${ps(staging)} -Recurse -Force
Start-Process -FilePath ${ps(Platform.resolvedExecutable)}
''');
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
    ], mode: ProcessStartMode.detached);
  }
}
