import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/models.dart';
import 'core/net/ping.dart';
import 'core/platform/vpn_channel.dart';
import 'core/state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF05070F),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(
    overrides: [prefsProvider.overrideWithValue(prefs)],
    child: const WaveApp(),
  ));
}

class WaveApp extends ConsumerStatefulWidget {
  const WaveApp({super.key});

  @override
  ConsumerState<WaveApp> createState() => _WaveAppState();
}

class _WaveAppState extends ConsumerState<WaveApp> {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
  }

  Future<void> _initDeepLinks() async {
    VpnChannel.onLink(_handleIncomingLink);
    final initial = await VpnChannel.initialLink();
    if (initial != null && initial.trim().isNotEmpty) {
      _handleIncomingLink(initial);
    }
  }

  Future<void> _handleIncomingLink(String link) async {
    try {
      final sub = await ref.read(subsProvider.notifier).importInput(link);
      final st = ref.read(settingsProvider);
      if (st.activeSubId == null) {
        final firstSupported = sub.nodes.where((n) => n.supported).firstOrNull;
        ref.read(settingsProvider.notifier).setActive(sub.id, firstSupported?.id);
      }
      _toast('Подписка «${sub.name}» импортирована (${sub.nodes.length} нод)');
    } catch (e) {
      _toast('Ошибка импорта: $e', isError: true);
    }
  }

  void _toast(String msg, {bool isError = false}) {
    _messengerKey.currentState?.clearSnackBars();
    _messengerKey.currentState?.showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
      backgroundColor: isError ? const Color(0xFFD32F2F) : const Color(0xFF0F172A),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: isError ? Colors.redAccent : const Color(0xFF00F2FE).withOpacity(0.4)),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wave',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF05070F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00F2FE),
          secondary: Color(0xFF4FACFE),
          surface: Color(0xFF0B1120),
        ),
        useMaterial3: true,
      ),
      home: WaveHomeScreen(onToast: _toast),
    );
  }
}

class WaveHomeScreen extends ConsumerStatefulWidget {
  final void Function(String msg, {bool isError}) onToast;
  const WaveHomeScreen({super.key, required this.onToast});

  @override
  ConsumerState<WaveHomeScreen> createState() => _WaveHomeScreenState();
}

class _WaveHomeScreenState extends ConsumerState<WaveHomeScreen> with SingleTickerProviderStateMixin {
  int _tab = 0;
  late final AnimationController _waveCtrl;
  DateTime? _connectedSince;
  Timer? _clockTimer;
  String _elapsed = '00:00:00';

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final st = ref.read(vpnProvider).status;
      if (st == VpnStatus.connected) {
        _connectedSince ??= DateTime.now();
        final d = DateTime.now().difference(_connectedSince!);
        final hh = d.inHours.toString().padLeft(2, '0');
        final mm = (d.inMinutes % 60).toString().padLeft(2, '0');
        final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
        if (mounted) setState(() => _elapsed = '$hh:$mm:$ss');
      } else if (_connectedSince != null) {
        _connectedSince = null;
        if (mounted) setState(() => _elapsed = '00:00:00');
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _waveCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vpn = ref.watch(vpnProvider);
    final subs = ref.watch(subsProvider);
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _waveCtrl,
              builder: (_, __) => CustomPaint(
                painter: WaveBackgroundPainter(
                  phase: _waveCtrl.value * 2 * pi,
                  connected: vpn.status == VpnStatus.connected,
                  connecting: vpn.status == VpnStatus.connecting,
                  trafficSpeed: vpn.down + vpn.up,
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _buildTopBar(vpn, subs),
                Expanded(
                  child: IndexedStack(
                    index: _tab,
                    children: [
                      _DashboardTab(
                        vpn: vpn,
                        subs: subs,
                        settings: settings,
                        elapsed: _elapsed,
                        onOpenAddSub: () => _showAddSubscriptionModal(context),
                        onToast: widget.onToast,
                      ),
                      _SubscriptionsTab(
                        subs: subs,
                        settings: settings,
                        onOpenAddSub: () => _showAddSubscriptionModal(context),
                        onToast: widget.onToast,
                      ),
                      _RoutingTab(
                        settings: settings,
                        onToast: widget.onToast,
                      ),
                      _LogsTab(onToast: widget.onToast),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildDockBar(),
    );
  }

  Widget _buildTopBar(VpnState vpn, List<Subscription> subs) {
    final isConn = vpn.status == VpnStatus.connected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [Color(0xFF00F2FE), Color(0xFF4FACFE)]),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00F2FE).withOpacity(isConn ? 0.55 : 0.2),
                  blurRadius: 14,
                ),
              ],
            ),
            child: const Icon(Icons.waves_rounded, color: Color(0xFF05070F), size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'WAVE',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: 2.2),
              ),
              Text(
                isConn
                    ? 'RIDING THE WAVE • SING-BOX'
                    : (vpn.status == VpnStatus.connecting ? 'CONNECTING TUNNEL...' : 'ABYSSAL CORE READY'),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.1,
                  color: isConn ? const Color(0xFF00F2FE) : Colors.white54,
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Сканировать QR',
            onPressed: () => _openQrScanner(context),
            icon: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF00F2FE)),
          ),
          IconButton(
            tooltip: 'Добавить подписку / ключ',
            onPressed: () => _showAddSubscriptionModal(context),
            icon: const Icon(Icons.add_circle_outline_rounded, color: Color(0xFF00F2FE)),
          ),
        ],
      ),
    );
  }

  Widget _buildDockBar() {
    const items = [
      (Icons.power_settings_new_rounded, 'Wave'),
      (Icons.layers_rounded, 'Подписки'),
      (Icons.alt_route_rounded, 'Роутинг'),
      (Icons.terminal_rounded, 'Логи'),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withOpacity(0.75),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFF00F2FE).withOpacity(0.18)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(items.length, (i) {
                  final active = _tab == i;
                  return Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _tab = i),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            items[i].$1,
                            size: 22,
                            color: active ? const Color(0xFF00F2FE) : Colors.white54,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            items[i].$2,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                              color: active ? const Color(0xFF00F2FE) : Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAddSubscriptionModal(BuildContext context) async {
    final ctrl = TextEditingController();
    var busy = false;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B1120),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.waves_rounded, color: Color(0xFF00F2FE)),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Импорт подписки или ключа',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF00F2FE)),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openQrScanner(context);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Поддерживаются: https:// подписки, happ://, incy://, v2raytun://, clash://, hiddify://, vless://, vmess://, hy2://, trojan://, ss://, tuic://, wg://, Sing-box JSON и Clash YAML.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                maxLines: 4,
                minLines: 2,
                decoration: InputDecoration(
                  hintText: 'https://... или happ://add/... или vless://...',
                  filled: true,
                  fillColor: const Color(0xFF05070F),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: const Color(0xFF00F2FE).withOpacity(0.25)),
                  ),
                  suffixIcon: IconButton(
                    tooltip: 'Вставить из буфера',
                    icon: const Icon(Icons.content_paste_rounded, color: Color(0xFF00F2FE)),
                    onPressed: () async {
                      final d = await Clipboard.getData(Clipboard.kTextPlain);
                      if (d?.text != null) ctrl.text = d!.text!.trim();
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00F2FE),
                    foregroundColor: const Color(0xFF05070F),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: busy
                      ? null
                      : () async {
                          var text = ctrl.text.trim();
                          if (text.isEmpty) {
                            final clip = await Clipboard.getData(Clipboard.kTextPlain);
                            text = clip?.text?.trim() ?? '';
                          }
                          if (text.isEmpty) {
                            widget.onToast('Буфер обмена и поле ввода пусты', isError: true);
                            return;
                          }
                          setModal(() => busy = true);
                          try {
                            final sub = await ref.read(subsProvider.notifier).importInput(text);
                            final st = ref.read(settingsProvider);
                            if (st.activeSubId == null) {
                              final firstNode = sub.nodes.where((n) => n.supported).firstOrNull;
                              ref.read(settingsProvider.notifier).setActive(sub.id, firstNode?.id);
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                            widget.onToast('Добавлено: ${sub.name} (${sub.nodes.length} нод)');
                          } catch (e) {
                            setModal(() => busy = false);
                            widget.onToast('$e', isError: true);
                          }
                        },
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF05070F)),
                        )
                      : const Icon(Icons.bolt_rounded),
                  label: Text(
                    busy ? 'Загрузка и парсинг...' : 'Импортировать в Wave',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openQrScanner(BuildContext context) async {
    var scanned = false;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text('Сканировать QR подписки или ключа'),
        ),
        body: MobileScanner(
          onDetect: (capture) async {
            if (scanned) return;
            final code = capture.barcodes.firstOrNull?.rawValue;
            if (code == null || code.trim().isEmpty) return;
            scanned = true;
            Navigator.of(ctx).pop();
            try {
              final sub = await ref.read(subsProvider.notifier).importInput(code.trim());
              final st = ref.read(settingsProvider);
              if (st.activeSubId == null) {
                final firstNode = sub.nodes.where((n) => n.supported).firstOrNull;
                ref.read(settingsProvider.notifier).setActive(sub.id, firstNode?.id);
              }
              widget.onToast('Подписка «${sub.name}» импортирована (${sub.nodes.length} нод)');
            } catch (e) {
              widget.onToast('Ошибка QR-импорта: $e', isError: true);
            }
          },
        ),
      ),
    ));
  }
}

// ───────────────────────── TAB 1: DASHBOARD ─────────────────────────

class _DashboardTab extends ConsumerWidget {
  final VpnState vpn;
  final List<Subscription> subs;
  final Settings settings;
  final String elapsed;
  final VoidCallback onOpenAddSub;
  final void Function(String msg, {bool isError}) onToast;

  const _DashboardTab({
    required this.vpn,
    required this.subs,
    required this.settings,
    required this.elapsed,
    required this.onOpenAddSub,
    required this.onToast,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isConn = vpn.status == VpnStatus.connected;
    final isConnecting = vpn.status == VpnStatus.connecting;
    final activeSub = subs.where((s) => s.id == settings.activeSubId).firstOrNull ?? subs.firstOrNull;
    final activeNode = activeSub?.nodes.where((n) => n.id == settings.activeNodeId).firstOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
      children: [
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: () {
              if (isConn || isConnecting) {
                ref.read(vpnProvider.notifier).disconnect();
              } else {
                ref.read(vpnProvider.notifier).connect();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 350),
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: isConn
                      ? [const Color(0xFF00F2FE).withOpacity(0.35), const Color(0xFF0F172A).withOpacity(0.9)]
                      : [const Color(0xFF1E293B).withOpacity(0.6), const Color(0xFF090D16)],
                ),
                border: Border.all(
                  width: 2.5,
                  color: isConn
                      ? const Color(0xFF00F2FE)
                      : (isConnecting ? Colors.amberAccent : const Color(0xFF00F2FE).withOpacity(0.25)),
                ),
                boxShadow: [
                  BoxShadow(
                    color: isConn ? const Color(0xFF00F2FE).withOpacity(0.45) : Colors.black54,
                    blurRadius: isConn ? 42 : 20,
                    spreadRadius: isConn ? 4 : 0,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isConnecting ? Icons.sync_rounded : Icons.power_settings_new_rounded,
                    size: 56,
                    color: isConn ? const Color(0xFF00F2FE) : Colors.white,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isConn ? 'ПОДКЛЮЧЕНО' : (isConnecting ? 'ЗАПУСК...' : 'СТАРТ'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                      color: isConn ? const Color(0xFF00F2FE) : Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    elapsed,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (vpn.message != null && vpn.message!.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
            ),
            child: Text(
              vpn.message!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.arrow_downward_rounded, size: 16, color: Color(0xFF00F2FE)),
                        SizedBox(width: 6),
                        Text('DOWNLOAD', style: TextStyle(fontSize: 11, color: Colors.white54, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_fmtBytes(vpn.down)}/s',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Всего: ${_fmtBytes(vpn.downTotal)}',
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.arrow_upward_rounded, size: 16, color: Color(0xFF4FACFE)),
                        SizedBox(width: 6),
                        Text('UPLOAD', style: TextStyle(fontSize: 11, color: Colors.white54, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_fmtBytes(vpn.up)}/s',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Всего: ${_fmtBytes(vpn.upTotal)}',
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _GlassCard(
          onTap: activeSub == null ? onOpenAddSub : () => _showNodePicker(context, ref, activeSub),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF00F2FE).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  activeNode?.flag ?? (activeSub != null ? '⚡' : '➕'),
                  style: const TextStyle(fontSize: 22),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      activeSub == null
                          ? 'Нет активной подписки'
                          : (activeNode?.name ?? 'Автовыбор (URL-Test Best Ping)'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      activeSub == null
                          ? 'Нажми, чтобы вставить ссылку Happ / VLESS / https'
                          : '${activeSub.name} • ${activeNode?.badge ?? "Sing-box Auto"}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF00F2FE)),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'РЕЖИМ МАРШРУТИЗАЦИИ WAVE',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white54, letterSpacing: 1.0),
              ),
              const SizedBox(height: 10),
              SegmentedButton<RouteMode>(
                segments: const [
                  ButtonSegment(
                    value: RouteMode.smart,
                    label: Text('Smart RU', style: TextStyle(fontSize: 12)),
                    icon: Icon(Icons.flash_on_rounded, size: 16),
                  ),
                  ButtonSegment(
                    value: RouteMode.global,
                    label: Text('Global', style: TextStyle(fontSize: 12)),
                    icon: Icon(Icons.public_rounded, size: 16),
                  ),
                  ButtonSegment(
                    value: RouteMode.perApp,
                    label: Text('Per-App', style: TextStyle(fontSize: 12)),
                    icon: Icon(Icons.apps_rounded, size: 16),
                  ),
                ],
                selected: {settings.mode},
                onSelectionChanged: (s) {
                  ref.read(settingsProvider.notifier).setMode(s.first);
                  if (vpn.status == VpnStatus.connected) {
                    ref.read(vpnProvider.notifier).reconnect();
                  }
                },
              ),
              if (isConn) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final ms = await urlTestViaLocalProxy();
                      onToast(ms != null ? 'Реальный HTTP URL-test через туннель: $ms ms' : 'URL-test не прошёл', isError: ms == null);
                    },
                    icon: const Icon(Icons.speed_rounded, size: 18, color: Color(0xFF00F2FE)),
                    label: const Text('Проверить задержку активного туннеля (HTTP 204)'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _showNodePicker(BuildContext context, WidgetRef ref, Subscription sub) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0B1120),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final pings = ref.watch(pingProvider);
          final st = ref.watch(settingsProvider);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Серверы • ${sub.name}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => ref.read(pingProvider.notifier).pingSub(sub),
                      icon: const Icon(Icons.network_ping_rounded, size: 18, color: Color(0xFF00F2FE)),
                      label: const Text('Пинг всех'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  selected: st.activeNodeId == null,
                  selectedTileColor: const Color(0xFF00F2FE).withOpacity(0.12),
                  leading: const Text('⚡', style: TextStyle(fontSize: 22)),
                  title: const Text('Автовыбор (Sing-box URL-Test)', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Автоматически держит ноду с минимальной задержкой'),
                  onTap: () {
                    ref.read(settingsProvider.notifier).setActive(sub.id, null);
                    Navigator.pop(ctx);
                    ref.read(vpnProvider.notifier).reconnect();
                  },
                ),
                const Divider(height: 16, color: Colors.white12),
                Expanded(
                  child: ListView.builder(
                    itemCount: sub.nodes.length,
                    itemBuilder: (_, i) {
                      final n = sub.nodes[i];
                      final selected = st.activeSubId == sub.id && st.activeNodeId == n.id;
                      final p = pings[n.id];
                      return ListTile(
                        enabled: n.supported,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        selected: selected,
                        selectedTileColor: const Color(0xFF00F2FE).withOpacity(0.12),
                        leading: Text(n.flag, style: const TextStyle(fontSize: 22)),
                        title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(n.supported ? '${n.badge} • ${n.server}:${n.port}' : (n.reason ?? 'Не поддерживается')),
                        trailing: _PingBadge(ping: p),
                        onTap: !n.supported
                            ? null
                            : () {
                                ref.read(settingsProvider.notifier).setActive(sub.id, n.id);
                                Navigator.pop(ctx);
                                ref.read(vpnProvider.notifier).reconnect();
                              },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ───────────────────────── TAB 2: SUBSCRIPTIONS ─────────────────────────

class _SubscriptionsTab extends ConsumerWidget {
  final List<Subscription> subs;
  final Settings settings;
  final VoidCallback onOpenAddSub;
  final void Function(String msg, {bool isError}) onToast;

  const _SubscriptionsTab({
    required this.subs,
    required this.settings,
    required this.onOpenAddSub,
    required this.onToast,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pings = ref.watch(pingProvider);

    if (subs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.layers_clear_rounded, size: 58, color: Colors.white38),
              const SizedBox(height: 14),
              const Text(
                'Пока нет ни одной подписки',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'Добавь ссылку из Happ, Incy, V2RayTun, Marzban, Remnawave или отдельные ключи VLESS / Hysteria2.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 13),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00F2FE),
                  foregroundColor: const Color(0xFF05070F),
                ),
                onPressed: onOpenAddSub,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Добавить подписку', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Подписки и серверы', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            TextButton.icon(
              onPressed: () async {
                final failed = await ref.read(subsProvider.notifier).refreshAll();
                onToast(failed == 0 ? 'Все подписки обновлены' : 'Обновлено (ошибок: $failed)');
              },
              icon: const Icon(Icons.refresh_rounded, size: 18, color: Color(0xFF00F2FE)),
              label: const Text('Обновить все'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final sub in subs) ...[
          _GlassCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00F2FE).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        sub.url != null ? 'SUBSCRIPTION' : 'LOCAL KEYS',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF00F2FE)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        sub.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Пинг нод',
                      icon: const Icon(Icons.network_ping_rounded, size: 20, color: Color(0xFF00F2FE)),
                      onPressed: () => ref.read(pingProvider.notifier).pingSub(sub),
                    ),
                    if (sub.url != null)
                      IconButton(
                        tooltip: 'Обновить подписку',
                        icon: const Icon(Icons.sync_rounded, size: 20),
                        onPressed: () async {
                          try {
                            await ref.read(subsProvider.notifier).refresh(sub.id);
                            onToast('Подписка «${sub.name}» обновлена');
                          } catch (e) {
                            onToast('$e', isError: true);
                          }
                        },
                      ),
                    if (sub.supportUrl != null)
                      IconButton(
                        tooltip: 'Поддержка провайдера',
                        icon: const Icon(Icons.support_agent_rounded, size: 20),
                        onPressed: () => launchUrl(Uri.parse(sub.supportUrl!), mode: LaunchMode.externalApplication),
                      ),
                    IconButton(
                      tooltip: 'Удалить',
                      icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                      onPressed: () => ref.read(subsProvider.notifier).remove(sub.id),
                    ),
                  ],
                ),
                if (!sub.unlimited || sub.expire > 0) ...[
                  const SizedBox(height: 10),
                  if (!sub.unlimited) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: (sub.used / sub.total).clamp(0.0, 1.0),
                        minHeight: 7,
                        backgroundColor: Colors.white12,
                        valueColor: const AlwaysStoppedAnimation(Color(0xFF00F2FE)),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        sub.unlimited ? 'Безлимитный трафик' : '${_fmtBytes(sub.used)} / ${_fmtBytes(sub.total)}',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      if (sub.expire > 0)
                        Text(
                          _fmtExpire(sub.expire),
                          style: const TextStyle(fontSize: 12, color: Color(0xFF00F2FE), fontWeight: FontWeight.w600),
                        ),
                    ],
                  ),
                ],
                if (sub.announce != null && sub.announce!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(sub.announce!, style: const TextStyle(fontSize: 12, color: Colors.amberAccent)),
                ],
                const Divider(height: 18, color: Colors.white12),
                for (final node in sub.nodes)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: !node.supported
                        ? null
                        : () {
                            ref.read(settingsProvider.notifier).setActive(sub.id, node.id);
                            ref.read(vpnProvider.notifier).reconnect();
                          },
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: (settings.activeSubId == sub.id && settings.activeNodeId == node.id)
                            ? const Color(0xFF00F2FE).withOpacity(0.14)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: (settings.activeSubId == sub.id && settings.activeNodeId == node.id)
                              ? const Color(0xFF00F2FE).withOpacity(0.5)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(node.flag, style: const TextStyle(fontSize: 19)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  node.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  node.supported ? '${node.badge} • ${node.server}:${node.port}' : (node.reason ?? 'Не поддерживается'),
                                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                                ),
                              ],
                            ),
                          ),
                          _PingBadge(ping: pings[node.id]),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

// ───────────────────────── TAB 3: ROUTING & SPLIT TUNNEL ─────────────────────────

class _RoutingTab extends ConsumerStatefulWidget {
  final Settings settings;
  final void Function(String msg, {bool isError}) onToast;

  const _RoutingTab({required this.settings, required this.onToast});

  @override
  ConsumerState<_RoutingTab> createState() => _RoutingTabState();
}

class _RoutingTabState extends ConsumerState<_RoutingTab> {
  late final TextEditingController _uaCtrl;

  @override
  void initState() {
    super.initState();
    _uaCtrl = TextEditingController(text: widget.settings.userAgent);
  }

  @override
  void dispose() {
    _uaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
      children: [
        const Text('Маршрутизация и заголовки', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        _GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Режим туннелирования Sing-box', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              RadioListTile<RouteMode>(
                value: RouteMode.smart,
                groupValue: s.mode,
                activeColor: const Color(0xFF00F2FE),
                title: const Text('Smart Wave (RU напрямую)'),
                subtitle: const Text('Сайты .ru, .рф, Госуслуги, банки и РФ IP идут напрямую без прокси'),
                onChanged: (v) => ref.read(settingsProvider.notifier).setMode(v!),
              ),
              RadioListTile<RouteMode>(
                value: RouteMode.global,
                groupValue: s.mode,
                activeColor: const Color(0xFF00F2FE),
                title: const Text('Global Wave (Весь трафик)'),
                subtitle: const Text('Весь трафик устройства направляется через интерфейс wave0'),
                onChanged: (v) => ref.read(settingsProvider.notifier).setMode(v!),
              ),
              RadioListTile<RouteMode>(
                value: RouteMode.perApp,
                groupValue: s.mode,
                activeColor: const Color(0xFF00F2FE),
                title: const Text('Per-App Proxy (Раздельное туннелирование)'),
                subtitle: Text('Выбрано приложений: ${s.packages.length}'),
                onChanged: (v) => ref.read(settingsProvider.notifier).setMode(v!),
              ),
              if (s.mode == RouteMode.perApp) ...[
                const Divider(color: Colors.white12),
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<PerAppMode>(
                        segments: const [
                          ButtonSegment(value: PerAppMode.allow, label: Text('Только выбранные')),
                          ButtonSegment(value: PerAppMode.deny, label: Text('Кроме выбранных')),
                        ],
                        selected: {s.perAppMode},
                        onSelectionChanged: (v) => ref.read(settingsProvider.notifier).setPerAppMode(v.first),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _openAppSelector(context),
                    icon: const Icon(Icons.apps_rounded),
                    label: const Text('Выбрать приложения на устройстве'),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        _GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('HTTP User-Agent для подписок', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text(
                'Используется при обращении к панелям Marzban, Remnawave, 3x-ui и Happ-совместимым подпискам.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _uaCtrl,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF05070F),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.save_rounded, color: Color(0xFF00F2FE)),
                    onPressed: () {
                      ref.read(settingsProvider.notifier).setUserAgent(_uaCtrl.text);
                      widget.onToast('User-Agent сохранён');
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openAppSelector(BuildContext context) async {
    final apps = await VpnChannel.installedApps();
    if (!context.mounted) return;
    final selected = {...ref.read(settingsProvider).packages};
    var showSystem = false;
    var query = '';
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B1120),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          final filtered = apps.where((a) {
            if (!showSystem && a.system) return false;
            if (query.isEmpty) return true;
            return a.name.toLowerCase().contains(query.toLowerCase()) ||
                a.package.toLowerCase().contains(query.toLowerCase());
          }).toList();
          return FractionallySizedBox(
            heightFactor: 0.85,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Приложения Per-App Proxy', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                      FilterChip(
                        label: const Text('Системные'),
                        selected: showSystem,
                        onSelected: (v) => setModal(() => showSystem = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    decoration: InputDecoration(
                      hintText: 'Поиск по названию или пакету...',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: const Color(0xFF05070F),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onChanged: (v) => setModal(() => query = v),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final app = filtered[i];
                        final on = selected.contains(app.package);
                        return CheckboxListTile(
                          value: on,
                          activeColor: const Color(0xFF00F2FE),
                          title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(app.package, style: const TextStyle(fontSize: 11, color: Colors.white54)),
                          onChanged: (v) {
                            setModal(() {
                              if (v == true) {
                                selected.add(app.package);
                              } else {
                                selected.remove(app.package);
                              }
                            });
                            ref.read(settingsProvider.notifier).setPackages(selected.toList());
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ───────────────────────── TAB 4: CORE LOGS ─────────────────────────

class _LogsTab extends StatefulWidget {
  final void Function(String msg, {bool isError}) onToast;
  const _LogsTab({required this.onToast});

  @override
  State<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<_LogsTab> {
  String _logs = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final l = await VpnChannel.logs();
    if (mounted && l != _logs) setState(() => _logs = l);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Журнал ядра Sing-box', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              IconButton(
                tooltip: 'Скопировать логи',
                icon: const Icon(Icons.copy_rounded, color: Color(0xFF00F2FE)),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _logs));
                  widget.onToast('Логи скопированы в буфер обмена');
                },
              ),
              IconButton(
                tooltip: 'Обновить',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _refresh,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _GlassCard(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  _logs.isEmpty ? '[WAVE CORE] Ожидание запуска туннеля...' : _logs,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Color(0xFFA5F3FC)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── SHARED WIDGETS & PAINTER ─────────────────────────

class _GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const _GlassCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.68),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF00F2FE).withOpacity(0.16)),
      ),
      child: child,
    );
    return onTap != null ? InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap, child: box) : box;
  }
}

class _PingBadge extends StatelessWidget {
  final int? ping;
  const _PingBadge({this.ping});

  @override
  Widget build(BuildContext context) {
    if (ping == null) return const SizedBox.shrink();
    if (ping == PingNotifier.pending) {
      return const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (ping == PingNotifier.udp) {
      return const Text('UDP', style: TextStyle(fontSize: 11, color: Color(0xFF4FACFE), fontWeight: FontWeight.w700));
    }
    if (ping! < 0) {
      return const Text('timeout', style: TextStyle(fontSize: 11, color: Colors.redAccent));
    }
    final color = ping! < 90
        ? Colors.greenAccent
        : (ping! < 180 ? const Color(0xFF00F2FE) : Colors.amberAccent);
    return Text(
      '$ping ms',
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color, fontFamily: 'monospace'),
    );
  }
}

class WaveBackgroundPainter extends CustomPainter {
  final double phase;
  final bool connected;
  final bool connecting;
  final int trafficSpeed;

  WaveBackgroundPainter({
    required this.phase,
    required this.connected,
    required this.connecting,
    required this.trafficSpeed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final boost = connected ? (1.0 + (log(trafficSpeed + 1) / 18.0).clamp(0.0, 1.4)) : (connecting ? 0.85 : 0.45);
    final baseHeight = size.height * (connected ? 0.62 : 0.76);

    for (var layer = 0; layer < 3; layer++) {
      final path = Path();
      final amp = (16.0 + layer * 9.0) * boost;
      final freq = 1.4 + layer * 0.45;
      final layerPhase = phase * (1.0 + layer * 0.35) + layer * 1.1;
      final yOffset = baseHeight + layer * 28.0;

      path.moveTo(0, size.height);
      path.lineTo(0, yOffset);
      for (double x = 0; x <= size.width; x += 6) {
        final y = yOffset + sin((x / size.width * 2 * pi * freq) + layerPhase) * amp;
        path.lineTo(x, y);
      }
      path.lineTo(size.width, size.height);
      path.close();

      final color = connected
          ? const Color(0xFF00F2FE).withOpacity(0.11 - layer * 0.025)
          : const Color(0xFF4FACFE).withOpacity(0.06 - layer * 0.015);
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant WaveBackgroundPainter old) =>
      old.phase != phase || old.connected != connected || old.trafficSpeed != trafficSpeed;
}

String _fmtBytes(int b) {
  if (b <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String _fmtExpire(int unixSec) {
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
  final diff = dt.difference(DateTime.now()).inDays;
  if (diff < 0) return 'Истекла';
  return 'Ещё $diff дн.';
}
