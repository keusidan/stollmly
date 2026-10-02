import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../net/host_client.dart';
import '../update/updater.dart';
import 'widgets.dart';

/// LAN 上の stollmly-host を一覧表示し、タップ 1 回で接続する画面。
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final Map<String, HostInfo> _found = {};
  double? _progress;
  String? _connectingId;
  final _manualAddress = TextEditingController();
  final _manualPort = TextEditingController(text: '$defaultHostPort');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  @override
  void dispose() {
    _manualAddress.dispose();
    _manualPort.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    if (_progress != null) return;
    setState(() {
      _found.clear();
      _progress = 0;
    });
    await AppScope.read(context).discover(
      onFound: (h) {
        if (mounted) setState(() => _found[h.id] = h);
      },
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (mounted) setState(() => _progress = null);
  }

  Future<void> _connect(HostInfo info) async {
    final state = AppScope.read(context);
    if (!info.compatible) {
      showError(context, 'ホストのバージョンが合いません (protocol ${info.protocol})。アプリとホストを最新にしてください。');
      return;
    }
    String? token;
    final saved = state.settings.hosts.where((h) => h.id == info.id).firstOrNull;
    if (info.authRequired && (saved?.token == null)) {
      token = await _askToken(info);
      if (token == null) return;
    }
    setState(() => _connectingId = info.id);
    try {
      await state.connectTo(info, token: token);
      if (mounted) showInfo(context, '「${info.name}」に接続しました');
    } on HostException catch (e) {
      if (!mounted) return;
      if (e.unauthorized) {
        final retry = await _askToken(info);
        if (retry != null) {
          try {
            await state.connectTo(info, token: retry);
          } catch (e) {
            if (mounted) showError(context, e);
          }
        }
      } else {
        showError(context, e);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  Future<String?> _askToken(HostInfo info) async {
    final controller = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('「${info.name}」のトークン'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(helperText: 'ホスト側で --token に指定した文字列'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('接続')),
        ],
      ),
    );
    controller.dispose();
    return (token == null || token.isEmpty) ? null : token;
  }

  Future<void> _connectManual() async {
    final state = AppScope.read(context);
    final port = int.tryParse(_manualPort.text.trim()) ?? defaultHostPort;
    try {
      final info = await state.probeManual(_manualAddress.text, port);
      setState(() => _found[info.id] = info);
      await _connect(info);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final active = state.activeHost;
    final scanning = _progress != null;

    return Scaffold(
      appBar: AppBar(title: const Text('LLM ホストに接続')),
      body: RefreshIndicator(
        onRefresh: _scan,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (active != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            state.connection == ConnectionStatus.connected ? Icons.check_circle : Icons.error_outline,
                            color: state.connection == ConnectionStatus.connected
                                ? Colors.green
                                : theme.colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(active.name, style: theme.textTheme.titleMedium)),
                          TextButton(
                            onPressed: state.connection == ConnectionStatus.connecting ? null : () => state.reconnect(),
                            child: const Text('再接続'),
                          ),
                        ],
                      ),
                      Text('${active.address}:${active.port}', style: theme.textTheme.bodySmall),
                      if (state.connectionError != null && state.connection == ConnectionStatus.error)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(state.connectionError!, style: TextStyle(color: theme.colorScheme.error)),
                        ),
                      if (state.models.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: state.models.contains(state.settings.model) ? state.settings.model : null,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '使うモデル', border: OutlineInputBorder()),
                          items: [for (final m in state.models) DropdownMenuItem(value: m, child: Text(m))],
                          onChanged: (m) => m == null ? null : state.selectModel(m),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Text('見つかったホスト', style: theme.textTheme.titleMedium)),
                TextButton.icon(
                  onPressed: scanning ? null : _scan,
                  icon: const Icon(Icons.radar),
                  label: Text(scanning ? '探しています…' : 'もう一度探す'),
                ),
              ],
            ),
            if (scanning) LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            const SizedBox(height: 8),
            if (_found.isEmpty && !scanning)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('ホストが見つかりませんでした。次を確認してください:'),
                      const SizedBox(height: 8),
                      const Text('1. LLM が入っている PC で stollmly-host を起動している'),
                      const Text('2. スマホと PC が同じ Wi-Fi / LAN につながっている'),
                      const Text('3. PC のファイアウォールで TCP 47320 と UDP 47321 を許可している'),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => launchUrl(
                          Uri.parse('https://github.com/$updateRepo#llm-ホストのセットアップ'),
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.help_outline),
                        label: const Text('セットアップ手順を開く'),
                      ),
                    ],
                  ),
                ),
              ),
            for (final h in _found.values)
              Card(
                child: ListTile(
                  leading: Icon(switch (h.os) {
                    'linux' => Icons.computer,
                    'macos' => Icons.laptop_mac,
                    'windows' => Icons.desktop_windows,
                    _ => Icons.dns,
                  }),
                  title: Text(h.name),
                  subtitle: Text('${h.address}  ·  ${h.os}  ·  v${h.version}${h.authRequired ? '  ·  🔒' : ''}'),
                  trailing: _connectingId == h.id
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : (active?.id == h.id && state.connection == ConnectionStatus.connected)
                      ? const Icon(Icons.check, color: Colors.green)
                      : const Icon(Icons.chevron_right),
                  onTap: _connectingId == null ? () => _connect(h) : null,
                ),
              ),
            const SizedBox(height: 24),
            ExpansionTile(
              title: const Text('IP アドレスを直接入力'),
              childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _manualAddress,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'IP アドレス', hintText: '192.168.1.10'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _manualPort,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'ポート'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _connectManual, child: const Text('接続')),
                  ],
                ),
              ],
            ),
            if (state.settings.hosts.isNotEmpty)
              ExpansionTile(
                title: const Text('保存済みのホスト'),
                children: [
                  for (final h in state.settings.hosts)
                    ListTile(
                      title: Text(h.name),
                      subtitle: Text('${h.address}:${h.port}'),
                      trailing: IconButton(
                        tooltip: '削除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => state.forgetHost(h),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
