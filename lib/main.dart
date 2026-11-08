import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account/backup_service.dart';
import 'account/account_page.dart';
import 'account/api_client.dart';
import 'account/profile_page.dart';
import 'account/subscription_page.dart';
import 'account/subscription_service.dart';
import 'apk/apk_extractor_page.dart';
import 'applock/app_lock_page.dart';
import 'flashlight_page.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxFlutterInitialize;

import 'diary/diary_lock.dart';
import 'home/app_share.dart';
import 'home/home_page.dart';
import 'home/nav_prefs.dart';
import 'diary/journal_page.dart';
import 'diary/tasks_page.dart';
import 'downloader/downloader_page.dart';
import 'downloader/quick_download.dart';
import 'excel/excel_page.dart';
import 'excel/sheet_store.dart';
import 'pdf/pdf_scanner_page.dart';
import 'pdf/pdf_viewer_page.dart';
import 'pdf/pdf_store.dart';
import 'reels/reels_page.dart';
import 'sos/sos_page.dart';
import 'vpn/vpn_page.dart';
import 'zip/zip_page.dart';

/// Entry point of the quick download panel (QuickDownloadActivity): a small
/// panel over the current app instead of the full Abhi Utility.
@pragma('vm:entry-point')
void quickDownloadMain() => runApp(const QuickDownloadApp());

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize(); // PDF engine (PDFium) for the viewer/editor
  runApp(const AbhiUtilityApp());
}

class AbhiUtilityApp extends StatelessWidget {
  const AbhiUtilityApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Abhi Utility',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.amber, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.amber,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _homeTab = 0;
  static const _reelsTab = 3;
  static const _lockTab = 4;
  static const _scannerTab = 5;
  static const _viewerTab = 6;
  static const _diaryTab = 7;
  static const _downloaderTab = 8;
  static const _tasksTab = 9;
  static const _apkTab = 10;
  static const _zipTab = 11;
  static const _excelTab = 12;
  static const _sosTab = 13;
  static const _docsTab = 14;

  /// Every feature: drives both the Home page cards and the bottom bar.
  static const _features = [
    HomeFeature(tab: 1, icon: Icons.flashlight_on_outlined, title: 'Flashlight',
        subtitle: 'Shake to turn the torch on/off', color: Colors.amber),
    HomeFeature(tab: 2, icon: Icons.vpn_key_outlined, title: 'VPN',
        subtitle: 'Free servers in many countries', color: Colors.teal),
    HomeFeature(tab: _reelsTab, icon: Icons.slow_motion_video, title: 'Reels',
        subtitle: 'Count reels & time on social apps', color: Colors.pink),
    HomeFeature(tab: _lockTab, icon: Icons.lock_outline, title: 'App Lock',
        subtitle: 'Limit or lock apps with a password', color: Colors.deepPurple),
    HomeFeature(tab: _scannerTab, icon: Icons.document_scanner_outlined, title: 'PDF Scanner',
        subtitle: 'Scan papers or photos into a PDF', color: Colors.orange),
    HomeFeature(tab: _viewerTab, icon: Icons.picture_as_pdf_outlined, title: 'PDF Viewer',
        subtitle: 'Open, read, sign & edit PDFs', color: Colors.red),
    HomeFeature(tab: _tasksTab, icon: Icons.checklist, title: 'Tasks',
        subtitle: 'Daily to-do list', color: Colors.green),
    HomeFeature(tab: _diaryTab, icon: Icons.menu_book, title: 'Diary',
        subtitle: 'Private diary with password', color: Colors.blue),
    HomeFeature(tab: _downloaderTab, icon: Icons.download_for_offline_outlined, title: 'Downloader',
        subtitle: 'Save videos & images from links', color: Colors.green),
    HomeFeature(tab: _apkTab, icon: Icons.android, title: 'APK Extractor',
        subtitle: 'Share or save the APK of any app', color: Colors.lightGreen),
    HomeFeature(tab: _zipTab, icon: Icons.folder_zip_outlined, title: 'Zip',
        subtitle: 'Zip, unzip, view & lock zip files', color: Colors.indigo),
    HomeFeature(tab: _excelTab, icon: Icons.table_chart_outlined, title: 'Excel Viewer',
        subtitle: 'View & edit Excel and CSV files', color: Color(0xFF1D6F42)),
    HomeFeature(tab: _sosTab, icon: Icons.sos, title: 'SOS',
        subtitle: 'Draw S on the lock screen to call for help', color: Colors.red),
    HomeFeature(tab: _docsTab, icon: Icons.description_outlined, title: 'Docs',
        subtitle: 'View & edit Word documents', color: Color(0xFF2B579A)),
  ];

  final _homeKey = GlobalKey<HomePageState>();
  final _reelsKey = GlobalKey<ReelsPageState>();
  final _lockKey = GlobalKey<AppLockPageState>();
  final _viewerKey = GlobalKey<PdfViewerHomePageState>();
  final _downloaderKey = GlobalKey<DownloaderPageState>();
  final _apkKey = GlobalKey<ApkExtractorPageState>();
  final _zipKey = GlobalKey<ZipPageState>();
  final _excelKey = GlobalKey<FileTabPageState>();
  final _docsKey = GlobalKey<FileTabPageState>();
  final _sosKey = GlobalKey<SosPageState>();
  int _tab = _homeTab;

  /// Features shown in the bottom bar after Home (chosen on the Home page).
  List<int> _pinned = const [_reelsTab, _lockTab, _viewerTab, _diaryTab];

  Future<void> _loadPinned() async {
    final pinned = await NavPrefs.load(_pinned, {for (final f in _features) f.tab});
    if (mounted) setState(() => _pinned = pinned);
  }

  void _setPinned(List<int> pinned) {
    setState(() => _pinned = pinned);
    NavPrefs.save(pinned);
  }

  @override
  void initState() {
    super.initState();
    // A backup that couldn't reach the server earlier: send it now if the server is live.
    BackupService.syncIfPending();
    _loadPinned();
    // Saved login + trial status first (works offline), then the latest from the server.
    ApiClient.instance.load().then((_) => _refreshAccount());
    SubscriptionService.instance.init(); // catches Play purchases that finish later
    // Leaving the app locks App Lock + Diary (not for the photo picker / our own system screens).
    _lifecycle = AppLifecycleListener(onResume: _refreshAccount, onPause: DiaryLock.onAppPaused);
    AccountPage.restoredVersion.addListener(_onRestored);
    ApiClient.instance.user.addListener(_onUserChanged);
    // Opened from the daily reel report notification -> show the Reels tab.
    const MethodChannel('abhi_utility/reels').invokeMethod<String>('initialTab').then((tab) {
      if (tab == 'reels' && mounted) setState(() => _tab = _reelsTab);
    }).catchError((_) {});

    // "Open with → Abhi Utility" for PDFs: while running…
    // "Share → Abhi Utility" links and the floating ⬇ button: while running…
    DownloaderPageState.channel.setMethodCallHandler((call) async {
      if (call.method == 'launch') await _openDownloader(call.arguments as Map);
    });
    // …and when the app was started by them.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final launch = await DownloaderPageState.channel.invokeMapMethod<String, dynamic>('takeLaunch');
      if (launch != null) await _openDownloader(launch);
    });

    PdfStore.channel.setMethodCallHandler((call) async {
      if (call.method == 'incomingPdf') await _openIncomingPdf(call.arguments as String);
    });
    // …and when the app was started by it.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final uri = await PdfStore.channel.invokeMethod<String>('takeIncoming');
      if (uri != null) await _openIncomingPdf(uri);
    });

    // "Open with → Abhi Utility" for Excel / CSV files: while running…
    sheetStore.channel.setMethodCallHandler((call) async {
      if (call.method == 'incomingSheet') await _openIncomingSheet(call.arguments as String);
    });
    // …and when the app was started by it.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final uri = await sheetStore.channel.invokeMethod<String>('takeIncoming');
      if (uri != null) await _openIncomingSheet(uri);
    });

    // "Open with → Abhi Utility" for Word documents: while running…
    docStore.channel.setMethodCallHandler((call) async {
      if (call.method == 'incomingDoc') await _openIncomingFile(_docsTab, _docsKey, call.arguments as String);
    });
    // …and when the app was started by it.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final uri = await docStore.channel.invokeMethod<String>('takeIncoming');
      if (uri != null) await _openIncomingFile(_docsTab, _docsKey, uri);
    });
  }

  Future<void> _openIncomingSheet(String uri) => _openIncomingFile(_excelTab, _excelKey, uri);

  Future<void> _openIncomingFile(int tab, GlobalKey<FileTabPageState> key, String uri) async {
    if (!mounted) return;
    _select(tab);
    // No trial / subscription: the tab shows the paywall instead of the file.
    if (!ApiClient.instance.hasAccess) return;
    await Future<void>.delayed(const Duration(milliseconds: 100)); // let the tab build
    await key.currentState?.openIncoming(uri);
  }

  Future<void> _openDownloader(Map launch) async {
    if (!mounted) return;
    _select(_downloaderTab);
    // Let the tab build before handing over the link.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await _downloaderKey.currentState?.handleLaunch(launch);
  }

  Future<void> _openIncomingPdf(String uri) async {
    if (!mounted) return;
    _select(_viewerTab);
    try {
      final path = await PdfStore.localCopy(uri);
      final name = path.split(RegExp(r'[\/]')).last;
      await _viewerKey.currentState?.openInViewer(path, name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open PDF: $e')));
      }
    }
  }

  late final AppLifecycleListener _lifecycle;

  /// Re-checks the free trial / subscription (it may have ended or been bought).
  Future<void> _refreshAccount() async {
    try {
      await ApiClient.instance.refreshAccount();
    } catch (_) {/* offline: the saved status is used */}
  }

  /// Bumped after a backup restore so the Diary and Tasks pages reload.
  int _dataVersion = 0;

  /// Logged in: Profile (details, subscription, referrals, backup). Logged out: login.
  void _openAccount() => ProfilePage.open(context);

  void _onRestored() {
    if (!mounted) return;
    DiaryLock.lockNow();
    setState(() => _dataVersion++);
    _homeKey.currentState?.refresh();
  }

  /// Diary and tasks belong to an account: another login (or logout) shows other data.
  int? _userId;
  bool _userKnown = false;

  void _onUserChanged() {
    final id = ApiClient.instance.user.value?.id;
    if (!_userKnown) {
      // First value from the saved login: nothing to reload yet.
      _userKnown = true;
      _userId = id;
      return;
    }
    if (id == _userId) return;
    _userId = id;
    _onRestored();
  }

  @override
  void dispose() {
    AccountPage.restoredVersion.removeListener(_onRestored);
    ApiClient.instance.user.removeListener(_onUserChanged);
    _lifecycle.dispose();
    super.dispose();
  }

  void _select(int i) {
    // App Lock and the Diary share one unlock: switching tabs keeps them open;
    // leaving the app (or a lock button) locks both (DiaryLock.onAppPaused).
    // Leaving the Downloader clears the link box (the link stays in Recent links).
    if (_tab == _downloaderTab && i != _downloaderTab) _downloaderKey.currentState?.reset();
    setState(() => _tab = i);
    if (i == _homeTab) _homeKey.currentState?.refresh();
    if (i == _reelsTab) _reelsKey.currentState?.refresh();
    if (i == _lockTab) _lockKey.currentState?.refresh();
    if (i == _viewerTab) _viewerKey.currentState?.refresh();
    if (i == _apkTab) _apkKey.currentState?.refresh();
    if (i == _zipTab) _zipKey.currentState?.refresh();
    if (i == _sosTab) _sosKey.currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back on a feature tab goes to Home; back on Home closes the app.
      canPop: _tab == _homeTab,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(_homeTab);
      },
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: () => _select(_homeTab),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('static/image/icon/logo_256.png', width: 34, height: 34),
                ),
                const SizedBox(width: 12),
                const Text('Abhi Utility'),
              ],
            ),
          ),
          actions: [
            ValueListenableBuilder<AccountUser?>(
              valueListenable: ApiClient.instance.user,
              builder: (context, user, _) => IconButton(
                tooltip: user == null ? 'Login / Register' : 'Profile',
                icon: Icon(user == null ? Icons.account_circle_outlined : Icons.account_circle),
                onPressed: _openAccount,
              ),
            ),
            IconButton(
              tooltip: 'Share this app',
              icon: const Icon(Icons.share),
              onPressed: () => AppShare.shareApk(context),
            ),
          ],
        ),
        // IndexedStack keeps all tabs alive, so the VPN state survives tab switches.
        // Without a free trial or subscription, every feature (not Home) is covered
        // by the paywall: register for the trial, or subscribe once it has ended.
        body: Stack(
          fit: StackFit.expand,
          children: [
            IndexedStack(
              index: _tab,
              children: [
                HomePage(
                  key: _homeKey,
                  features: _features,
                  onOpen: _select,
                  pinned: _pinned,
                  onPinnedChanged: _setPinned,
                ),
                const FlashlightPage(),
                const VpnPage(),
                ReelsPage(key: _reelsKey),
                // active: on screen and not behind the subscription paywall.
                AppLockPage(key: _lockKey, active: _tab == _lockTab && ApiClient.instance.hasAccess),
                const PdfScannerPage(),
                PdfViewerHomePage(key: _viewerKey),
                JournalPage(
                    key: ValueKey('journal$_dataVersion'),
                    active: _tab == _diaryTab && ApiClient.instance.hasAccess),
                DownloaderPage(key: _downloaderKey),
                TasksPage(key: ValueKey('tasks$_dataVersion')),
                ApkExtractorPage(key: _apkKey),
                ZipPage(key: _zipKey),
                FileTabPage(key: _excelKey, kind: excelKind),
                SosPage(key: _sosKey),
                FileTabPage(key: _docsKey, kind: docsKind),
              ],
            ),
            if (_tab != _homeTab)
              ListenableBuilder(
                listenable: Listenable.merge(
                    [ApiClient.instance.user, ApiClient.instance.entitlement, ApiClient.instance.offlineMode]),
                builder: (context, _) => ApiClient.instance.hasAccess
                    ? const SizedBox.shrink()
                    : Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: const PaywallView(locked: true),
                      ),
              ),
          ],
        ),
        // Home + the features pinned on the Home page. A feature opened from
        // Home that isn't pinned keeps Home highlighted.
        bottomNavigationBar: NavigationBar(
          selectedIndex: _pinned.contains(_tab) ? _pinned.indexOf(_tab) + 1 : 0,
          onDestinationSelected: (i) => _select(i == 0 ? _homeTab : _pinned[i - 1]),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            for (final tab in _pinned)
              NavigationDestination(
                icon: Icon(_features.firstWhere((f) => f.tab == tab).icon),
                label: _features.firstWhere((f) => f.tab == tab).title,
              ),
          ],
        ),
      ),
    );
  }
}
