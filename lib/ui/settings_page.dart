import 'package:flutter/material.dart';

import '../app_state.dart';
import '../update/updater.dart';
import 'connect_page.dart';
import 'output_format_page.dart';
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
            title: Text('直近の会話を渡す上限: 約 ${settings.contextChars} 文字'),
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
                const Text(
                  '直近の会話をそのまま AI に渡す量の上限です。古い内容は長期記憶が受け持ちます。'
                  'モデルのコンテキスト長を超えると失敗するので、大きくしすぎないでください。',
                ),
              ],
            ),
          ),
          header('長期記憶'),
          SwitchListTile(
            secondary: const Icon(Icons.psychology_outlined),
            title: const Text('長期記憶を使う'),
            subtitle: const Text('重要メモ・あらすじ・過去の発言の検索で、長いトークでも大事なことを忘れないようにします'),
            value: settings.memoryEnabled,
            onChanged: (v) {
              settings.memoryEnabled = v;
              state.commit();
            },
          ),
          if (settings.memoryEnabled) ...[
            _IntSlider(
              label: (v) => '整理する間隔: $v 往復ごと',
              value: settings.memoryInterval,
              min: 5,
              max: 50,
              step: 5,
              onChanged: (v) {
                settings.memoryInterval = v;
                state.commit();
              },
            ),
            _IntSlider(
              label: (v) => '重要メモの上限: 約 $v 字',
              value: settings.memoryFactsMaxChars,
              min: 1000,
              max: 6000,
              step: 500,
              onChanged: (v) {
                settings.memoryFactsMaxChars = v;
                state.commit();
              },
            ),
            _IntSlider(
              label: (v) => 'あらすじの長さ: 約 $v 字',
              value: settings.memorySynopsisChars,
              min: 500,
              max: 3000,
              step: 250,
              onChanged: (v) {
                settings.memorySynopsisChars = v;
                state.commit();
              },
            ),
            _IntSlider(
              label: (v) => 'そのまま渡す直近の会話: $v 往復',
              value: settings.recentTurns,
              min: 2,
              max: 20,
              step: 1,
              onChanged: (v) {
                settings.recentTurns = v;
                state.commit();
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.manage_search),
              title: const Text('過去の発言を検索して差し込む'),
              subtitle: Text('ホストの embedding モデル (${settings.embedModel}) を使います。無ければ自動で無効になります'),
              value: settings.retrievalEnabled,
              onChanged: (v) {
                settings.retrievalEnabled = v;
                state.memory.resetRetrieval();
                state.commit();
              },
            ),
            if (settings.retrievalEnabled)
              ListTile(
                leading: const Icon(Icons.hub_outlined),
                title: const Text('embedding モデル'),
                subtitle: Text(settings.embedModel),
                onTap: () async {
                  final controller = TextEditingController(text: settings.embedModel);
                  final value = await showDialog<String>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('embedding モデル'),
                      content: TextField(
                        controller: controller,
                        decoration: const InputDecoration(helperText: 'ホストで pull 済みのモデル名 (例: bge-m3)'),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, controller.text.trim()),
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  );
                  controller.dispose();
                  if (value != null && value.isNotEmpty) {
                    settings.embedModel = value;
                    state.memory.resetRetrieval();
                    state.commit();
                  }
                },
              ),
          ],
          header('トーク'),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('トークプロフィール'),
            subtitle: Text('既定: ${state.personaById(settings.defaultPersonaId)?.name ?? '未設定'}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PersonasPage())),
          ),
          ListTile(
            leading: const Icon(Icons.format_quote),
            title: const Text('出力フォーマット'),
            subtitle: Text(settings.outputFormat == null ? '既定 (*描写* と台詞を交互に書くチャット形式)' : '編集済み'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OutputFormatPage())),
          ),
          header('表示'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('自動'), icon: Icon(Icons.brightness_auto)),
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

class _IntSlider extends StatelessWidget {
  const _IntSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });

  final String Function(int value) label;
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(min, max);
    return ListTile(
      // アイコン付きのほかの項目と左端を揃える
      leading: const SizedBox(width: 24),
      title: Text(label(v)),
      subtitle: Slider(
        value: v.toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: (max - min) ~/ step,
        onChanged: (d) => onChanged((d / step).round() * step),
      ),
    );
  }
}
