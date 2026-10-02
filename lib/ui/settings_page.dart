import 'package:flutter/material.dart';

import '../app_state.dart';
import '../update/updater.dart';
import 'connect_page.dart';
import 'personas_page.dart';
import 'update_page.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.settings;
    final theme = Theme.of(context);

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          header('LLM'),
          ListTile(
            leading: const Icon(Icons.lan),
            title: const Text('接続先ホスト'),
            subtitle: Text(switch (state.connection) {
              ConnectionStatus.connected =>
                '${state.activeHost?.name} (${state.activeHost?.address}) · ${settings.model ?? 'モデル未選択'}',
              ConnectionStatus.connecting => '接続中…',
              _ => '未接続 — タップしてホストを選ぶ',
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectPage())),
          ),
          ListTile(
            leading: const Icon(Icons.thermostat),
            title: Text('創造性 (temperature): ${settings.temperature.toStringAsFixed(2)}'),
            subtitle: Slider(
              value: settings.temperature,
              min: 0,
              max: 1.5,
              divisions: 30,
              onChanged: (v) {
                settings.temperature = v;
                state.commit();
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.memory),
            title: Text('記憶する会話の長さ: 約 ${settings.contextChars} 文字'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Slider(
                  value: settings.contextChars.toDouble(),
                  min: 2000,
                  max: 64000,
                  divisions: 31,
                  onChanged: (v) {
                    settings.contextChars = v.round();
                    state.commit();
                  },
                ),
                const Text('大きくすると昔の会話も覚えますが、モデルのコンテキスト長を超えると失敗します。'),
              ],
            ),
          ),
          header('トーク'),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('トークプロフィール'),
            subtitle: Text('既定: ${state.personaById(settings.defaultPersonaId)?.name ?? '未設定'}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PersonasPage())),
          ),
          header('表示'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('端末に合わせる'), icon: Icon(Icons.brightness_auto)),
                ButtonSegment(value: 'light', label: Text('ライト'), icon: Icon(Icons.light_mode)),
                ButtonSegment(value: 'dark', label: Text('ダーク'), icon: Icon(Icons.dark_mode)),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (s) {
                settings.themeMode = s.first;
                state.commit();
              },
            ),
          ),
          header('アップデート'),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: const Text('アップデートを確認'),
            subtitle: Text('現在のバージョン: $appVersion'),
            trailing: state.availableUpdate != null
                ? Badge(label: const Text('NEW'), child: const Icon(Icons.chevron_right))
                : const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UpdatePage())),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.autorenew),
            title: const Text('起動時に新しいバージョンを確認する'),
            value: settings.checkUpdatesOnStart,
            onChanged: (v) {
              settings.checkUpdatesOnStart = v;
              state.commit();
            },
          ),
          header('このアプリについて'),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('データの保存場所'),
            subtitle: SelectableText(state.dataPath),
          ),
          const ListTile(
            leading: Icon(Icons.shield_outlined),
            title: Text('プライバシー'),
            subtitle: Text(
              '会話データはこの端末と、あなたの LAN 上の LLM ホストにしか送られません。'
              'アップデート確認のときだけ GitHub に接続します。',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('オープンソースライセンス'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Stollmly',
              applicationVersion: appVersion,
              applicationLegalese: '© 2026 keusidan — MIT License\n個人による非営利の実験的プロジェクトです。',
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
