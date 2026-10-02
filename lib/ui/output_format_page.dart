import 'package:flutter/material.dart';

import 'widgets.dart';

/// 出力フォーマット (AI の応答の書き方の指示) を編集する画面。
class OutputFormatPage extends StatefulWidget {
  const OutputFormatPage({super.key});

  @override
  State<OutputFormatPage> createState() => _OutputFormatPageState();
}

class _OutputFormatPageState extends State<OutputFormatPage> {
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: AppScope.read(context).outputFormat);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final state = AppScope.read(context);
    final text = _text.text.trim();
    // 既定と同じなら null にして、アプリ更新で既定が改善されたときに追従させる
    state.settings.outputFormat = (text.isEmpty || text == state.defaultOutputFormat.trim()) ? null : _text.text;
    state.commit();
    Navigator.pop(context);
  }

  Future<void> _reset() async {
    final state = AppScope.read(context);
    if (!await confirm(context, '既定に戻す', '編集した内容を破棄して、同梱の既定フォーマットに戻しますか？', ok: '戻す')) return;
    setState(() => _text.text = state.defaultOutputFormat);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('出力フォーマット'),
        actions: [
          TextButton(onPressed: _reset, child: const Text('既定に戻す')),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('保存')),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'AI に毎回渡す「応答の書き方」の指示です。すべてのキャラクターに共通で使われます。\n'
                '次の文字列は自動で置き換わります: '
                '{{char}} キャラ名 / {{user}} あなたの名前 / {{pov}} 視点 / {{tempo}} テンポ / '
                '{{openness}} 距離感 / {{length}} 長さ (キャラごとの設定)',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                state.settings.outputFormat == null ? '現在: 既定のフォーマット' : '現在: 編集済みのフォーマット',
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                minLines: 16,
                maxLines: null,
                style: const TextStyle(fontSize: 14, height: 1.5),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
