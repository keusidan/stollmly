import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'ui/characters_page.dart';
import 'ui/settings_page.dart';
import 'ui/talks_page.dart';
import 'ui/update_page.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 同梱フォントのライセンスを「オープンソースライセンス」画面に載せる
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Noto Sans JP'], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  final state = await AppState.load();
  runApp(StollmlyApp(state: state));
  await state.startup();
}

const _fontFamily = 'NotoSansJP';

class StollmlyApp extends StatelessWidget {
  const StollmlyApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          const seed = Color(0xFF7C4DFF);
          return MaterialApp(
            title: 'Stollmly',
            debugShowCheckedModeBanner: false,
            themeMode: switch (state.settings.themeMode) {
              'light' => ThemeMode.light,
              'dark' => ThemeMode.dark,
              _ => ThemeMode.system,
            },
            // 日本語ロケールにしておくと、OS のフォールバックフォントも日本語字形が選ばれる
            locale: const Locale('ja', 'JP'),
            supportedLocales: const [Locale('ja', 'JP')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true, fontFamily: _fontFamily),
            darkTheme: ThemeData(
              colorSchemeSeed: seed,
              brightness: Brightness.dark,
              useMaterial3: true,
              fontFamily: _fontFamily,
            ),
            home: const HomeShell(),
          );
        },
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _destinations = [
    (Icons.people_outline, Icons.people, 'キャラ'),
    (Icons.chat_bubble_outline, Icons.chat_bubble, 'トーク'),
    (Icons.settings_outlined, Icons.settings, '設定'),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pages = const [CharactersPage(), TalksPage(), SettingsPage()];
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final update = state.availableUpdate;
    final showBanner = update != null && state.settings.skippedVersion != update.tag;
    final stack = IndexedStack(index: _index, children: pages);
    final body = Column(
      children: [
        if (showBanner)
          SafeArea(
            bottom: false,
            child: MaterialBanner(
              leading: const Icon(Icons.system_update),
              content: Text('新しいバージョン ${update.tag} があります'),
              actions: [
                TextButton(
                  onPressed: () {
                    state.settings.skippedVersion = update.tag;
                    state.commit();
                  },
                  child: const Text('スキップ'),
                ),
                FilledButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UpdatePage())),
                  child: const Text('更新する'),
                ),
              ],
            ),
          ),
        Expanded(
          // バナーがステータスバー分の余白を使ったので、下のページの AppBar では二重に取らない
          child: showBanner ? MediaQuery.removePadding(context: context, removeTop: true, child: stack) : stack,
        ),
      ],
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations) NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3),
        ],
      ),
    );
  }
}
