import 'dart:io';

import 'package:flutter/material.dart';

import '../update/updater.dart';
import 'widgets.dart';

/// GitHub Releases から最新版を取得してアプリ内で更新する画面。
class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  bool _checking = false;
  bool _checked = false;
  double? _progress;
  String? _error;
  File? _downloaded;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      await AppScope.read(context).checkForUpdate();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
          _checked = true;
        });
      }
    }
  }

  Future<void> _update(ReleaseInfo release) async {
    final state = AppScope.read(context);
    if (!Updater.canSelfInstall) {
      await Updater.openReleasePage(release);
      return;
    }
    final asset = release.assetForThisPlatform;
    if (asset == null) {
      setState(() => _error = 'このプラットフォーム向けのファイル (${Updater.assetNameForPlatform}) がリリースにありません。');
      return;
    }
    setState(() {
      _error = null;
      _progress = 0;
    });
    try {
      final file = _downloaded ?? await Updater.download(asset, onProgress: (p) => setState(() => _progress = p));
      _downloaded = file;
      final outcome = await Updater.install(
        file,
        release,
        exitApp: () async {
          await state.flush();
          exit(0);
        },
      );
      if (!mounted) return;
      switch (outcome) {
        case InstallOutcome.needsPermission:
          showInfo(context, '「この提供元のアプリを許可」をオンにしてから、もう一度「更新する」を押してください。');
        case InstallOutcome.started:
          showInfo(context, 'インストーラーを起動しました');
        case InstallOutcome.openedInBrowser:
          break;
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final release = state.availableUpdate;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('アップデート')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('現在のバージョン'),
            subtitle: Text(appVersion),
            trailing: TextButton.icon(
              onPressed: _checking ? null : _check,
              icon: const Icon(Icons.refresh),
              label: const Text('確認'),
            ),
          ),
          const Divider(),
          if (_checking)
            const Center(
              child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
            ),
          if (!_checking && _checked && release == null && _error == null)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.check_circle, color: Colors.green),
              title: Text('最新版です'),
            ),
          if (release != null) ...[
            Text('新しいバージョン', style: theme.textTheme.labelLarge),
            Text(release.tag, style: theme.textTheme.headlineSmall),
            if (release.publishedAt != null) Text('公開: ${release.publishedAt!.toLocal()}'),
            const SizedBox(height: 12),
            if (release.body.trim().isNotEmpty)
              Card(
                child: Padding(padding: const EdgeInsets.all(12), child: Text(release.body.trim())),
              ),
            const SizedBox(height: 16),
            if (_progress != null) ...[
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
              const SizedBox(height: 4),
              Text('ダウンロード中… ${((_progress ?? 0) * 100).toStringAsFixed(0)}%'),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: _progress != null ? null : () => _update(release),
              icon: const Icon(Icons.download),
              label: Text(Updater.canSelfInstall ? 'ダウンロードして更新する' : 'リリースページを開く'),
            ),
            const SizedBox(height: 8),
            Text(
              Platform.isIOS
                  ? 'iOS ではアプリ自身による更新ができないため、AltStore / SideStore などで .ipa を入れ直してください。'
                  : Platform.isAndroid
                  ? 'ダウンロード後に Android のインストーラーが開きます。初回は「この提供元のアプリを許可」が必要です。'
                  : '更新後、アプリは自動で再起動します。',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
