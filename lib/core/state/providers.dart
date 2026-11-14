import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/rule_sets.dart';
import '../config/singbox_builder.dart';
import '../models.dart';
import '../net/ping.dart';
import '../parser/universal_parser.dart';
import '../platform/vpn_channel.dart';

final prefsProvider = Provider<SharedPreferences>((_) => throw UnimplementedError('prefs not initialised'));

// ───────────────────────── settings ─────────────────────────

class Settings {
  final RouteMode mode;
  final PerAppMode perAppMode;
  final List<String> packages;
  final String userAgent;
  final String? activeSubId;
  final String? activeNodeId; // null = auto (urltest)

  const Settings({
    required this.mode,
    required this.perAppMode,
    required this.packages,
    required this.userAgent,
    this.activeSubId,
    this.activeNodeId,
  });

  Settings copyWith({RouteMode? mode, PerAppMode? perAppMode, List<String>? packages, String? userAgent}) => Settings(
        mode: mode ?? this.mode,
        perAppMode: perAppMode ?? this.perAppMode,
        packages: packages ?? this.packages,
        userAgent: userAgent ?? this.userAgent,
        activeSubId: activeSubId,
        activeNodeId: activeNodeId,
      );

  Settings withActive(String? sub, String? node) => Settings(
        mode: mode,
        perAppMode: perAppMode,
        packages: packages,
        userAgent: userAgent,
        activeSubId: sub,
        activeNodeId: node,
      );
}

class SettingsNotifier extends Notifier<Settings> {
  late SharedPreferences _p;

  @override
  Settings build() {
    _p = ref.read(prefsProvider);
    return Settings(
      mode: RouteMode.values.firstWhere((e) => e.name == _p.getString('mode'), orElse: () => RouteMode.smart),
      perAppMode: PerAppMode.values.firstWhere((e) => e.name == _p.getString('perAppMode'), orElse: () => PerAppMode.allow),
      packages: _p.getStringList('packages') ?? const [],
      userAgent: _p.getString('ua') ?? SubscriptionFetcher.defaultUserAgent,
      activeSubId: _p.getString('activeSub'),
      activeNodeId: _p.getString('activeNode'),
    );
  }

  void setMode(RouteMode m) {
    _p.setString('mode', m.name);
    state = state.copyWith(mode: m);
  }

  void setPerAppMode(PerAppMode m) {
    _p.setString('perAppMode', m.name);
    state = state.copyWith(perAppMode: m);
  }

  void setPackages(List<String> p) {
    _p.setStringList('packages', p);
    state = state.copyWith(packages: p);
  }

  void setUserAgent(String ua) {
    final v = ua.trim().isEmpty ? SubscriptionFetcher.defaultUserAgent : ua.trim();
    _p.setString('ua', v);
    state = state.copyWith(userAgent: v);
  }

  void setActive(String? sub, String? node) {
    sub == null ? _p.remove('activeSub') : _p.setString('activeSub', sub);
    node == null ? _p.remove('activeNode') : _p.setString('activeNode', node);
    state = state.withActive(sub, node);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

// ───────────────────────── subscriptions ─────────────────────────

class SubsNotifier extends Notifier<List<Subscription>> {
  late SharedPreferences _p;
  final _fetcher = SubscriptionFetcher();

  @override
  List<Subscription> build() {
    _p = ref.read(prefsProvider);
    var list = <Subscription>[];
    try {
      final raw = _p.getString('subs');
      if (raw != null) {
        list = (jsonDecode(raw) as List).map((e) => Subscription.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      }
    } catch (_) {}
    Future.microtask(autoUpdate);
    return list;
  }

  void _save() => _p.setString('subs', jsonEncode(state.map((s) => s.toJson()).toList()));

  void _put(Subscription s) {
    final i = state.indexWhere((x) => x.id == s.id);
    state = i >= 0 ? [...state.take(i), s, ...state.skip(i + 1)] : [...state, s];
    _save();
  }

  Future<Subscription> importInput(String input) async {
    final t = LinkParser.parse(input);
    final Subscription sub;
    if (t.url != null) {
      final f = await _fetcher.fetch(t.url!, userAgent: ref.read(settingsProvider).userAgent);
      sub = _build(stableHash(t.url!), t.url, t.name, f.meta, SubscriptionDecoder.decode(f.body));
    } else {
      sub = _build(stableHash(t.body!), null, t.name, const SubscriptionMeta(), SubscriptionDecoder.decode(t.body!));
    }
    _put(sub);
    return sub;
  }

  Subscription _build(String id, String? url, String? hintName, SubscriptionMeta m, ParseResult r) {
    if (r.nodes.isEmpty) throw WaveException('В подписке нет ни одной ноды (пропущено: ${r.skipped})');
    return Subscription(
      id: id,
      name: m.title ?? hintName ?? (url != null ? (Uri.tryParse(url)?.host ?? 'Wave') : 'Импорт'),
      url: url,
      nodes: r.nodes,
      upload: m.upload,
      download: m.download,
      total: m.total,
      expire: m.expire,
      intervalHours: m.updateHours,
      supportUrl: m.supportUrl,
      announce: m.announce,
      webPage: m.webPage,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> refresh(String id) async {
    final old = state.firstWhere((s) => s.id == id);
    if (old.url == null) return;
    final f = await _fetcher.fetch(old.url!, userAgent: ref.read(settingsProvider).userAgent);
    final fresh = _build(old.id, old.url, old.name, f.meta, SubscriptionDecoder.decode(f.body));
    _put(fresh);
  }

  Future<int> refreshAll() async {
    var failed = 0;
    for (final s in [...state]) {
      try {
        await refresh(s.id);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  Future<void> autoUpdate() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final s in [...state]) {
      final due = s.updatedAt + (s.intervalHours <= 0 ? 24 : s.intervalHours) * 3600 * 1000;
      if (s.url != null && now > due) {
        try {
          await refresh(s.id);
        } catch (_) {}
      }
    }
  }

  void remove(String id) {
    state = state.where((s) => s.id != id).toList();
    _save();
    final st = ref.read(settingsProvider);
    if (st.activeSubId == id) ref.read(settingsProvider.notifier).setActive(null, null);
  }
}

final subsProvider = NotifierProvider<SubsNotifier, List<Subscription>>(SubsNotifier.new);

// ───────────────────────── vpn ─────────────────────────

enum VpnStatus { disconnected, connecting, connected, error }

class VpnState {
  final VpnStatus status;
  final int up, down, upTotal, downTotal; // bytes/s, bytes
  final String? message;
  final int apiPort;
  final String secret;
  final Map<String, String> tags; // node id -> outbound tag in the running config

  const VpnState({
    this.status = VpnStatus.disconnected,
    this.up = 0,
    this.down = 0,
    this.upTotal = 0,
    this.downTotal = 0,
    this.message,
    this.apiPort = 0,
    this.secret = '',
    this.tags = const {},
  });

  VpnState copyWith({
    VpnStatus? status,
    int? up,
    int? down,
    int? upTotal,
    int? downTotal,
    String? message,
    bool clearMessage = false,
    int? apiPort,
    String? secret,
    Map<String, String>? tags,
  }) =>
      VpnState(
        status: status ?? this.status,
        up: up ?? this.up,
        down: down ?? this.down,
        upTotal: upTotal ?? this.upTotal,
        downTotal: downTotal ?? this.downTotal,
        message: clearMessage ? null : (message ?? this.message),
        apiPort: apiPort ?? this.apiPort,
        secret: secret ?? this.secret,
        tags: tags ?? this.tags,
      );
}

class VpnNotifier extends Notifier<VpnState> {
  @override
  VpnState build() {
    final sub = VpnChannel.events.listen(_onEvent, onError: (_) {});
    ref.onDispose(sub.cancel);
    return const VpnState();
  }

  void _onEvent(Map<String, dynamic> e) {
    if (e['type'] == 'traffic') {
      state = state.copyWith(
        up: (e['up'] as num).toInt(),
        down: (e['down'] as num).toInt(),
        upTotal: (e['upTotal'] as num).toInt(),
        downTotal: (e['downTotal'] as num).toInt(),
      );
    } else if (e['type'] == 'state') {
      final s = switch (e['state']) {
        'connected' => VpnStatus.connected,
        'connecting' => VpnStatus.connecting,
        'error' => VpnStatus.error,
        _ => VpnStatus.disconnected,
      };
      final live = s == VpnStatus.connected;
      state = VpnState(
        status: s,
        up: live ? state.up : 0,
        down: live ? state.down : 0,
        upTotal: live ? state.upTotal : 0,
        downTotal: live ? state.downTotal : 0,
        message: e['message'] as String?,
        apiPort: state.apiPort,
        secret: state.secret,
        tags: live ? state.tags : const {},
      );
    }
  }

  Future<void> connect() async {
    if (state.status == VpnStatus.connecting || state.status == VpnStatus.connected) return;
    state = state.copyWith(status: VpnStatus.connecting, clearMessage: true);
    try {
      final st = ref.read(settingsProvider);
      final subs = ref.read(subsProvider);
      if (subs.isEmpty) throw WaveException('Сначала добавь подписку');
      final sub = subs.firstWhere((s) => s.id == st.activeSubId, orElse: () => subs.first);
      if (st.mode == RouteMode.perApp && st.perAppMode == PerAppMode.allow && st.packages.isEmpty) {
        throw WaveException('Per-App: выбери хотя бы одно приложение');
      }
      if (!await VpnChannel.prepare()) throw WaveException('VPN-разрешение не выдано');
      await VpnChannel.requestNotifications();
      final rs = st.mode == RouteMode.smart ? await RuleSets.ensure() : const RuleSetPaths(null, null);
      final cfg = SingboxBuilder.build(BuildInput(
        nodes: sub.nodes,
        selectedNodeId: st.activeSubId == sub.id ? st.activeNodeId : null,
        mode: st.mode,
        perAppMode: st.perAppMode,
        packages: st.packages,
        geositeRuPath: rs.geosite,
        geoipRuPath: rs.geoip,
      ));
      state = state.copyWith(apiPort: cfg.apiPort, secret: cfg.secret, tags: cfg.tagById);
      await VpnChannel.start(config: cfg.json, apiPort: cfg.apiPort, secret: cfg.secret);
    } on PlatformException catch (e) {
      state = state.copyWith(status: VpnStatus.error, message: e.message ?? e.code);
    } on WaveException catch (e) {
      state = state.copyWith(status: VpnStatus.error, message: e.message);
    } catch (e) {
      state = state.copyWith(status: VpnStatus.error, message: '$e');
    }
  }

  Future<void> disconnect() => VpnChannel.stop();

  Future<void> reconnect() async {
    if (state.status != VpnStatus.connected) return;
    await VpnChannel.stop();
    for (var i = 0; i < 20 && state.status != VpnStatus.disconnected; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    await connect();
  }
}

final vpnProvider = NotifierProvider<VpnNotifier, VpnState>(VpnNotifier.new);

// ───────────────────────── ping ─────────────────────────

class PingNotifier extends Notifier<Map<String, int>> {
  static const pending = -2, fail = -1, udp = -3;

  @override
  Map<String, int> build() => {};

  void _set(Map<String, int> m) => state = {...state, ...m};

  Future<void> pingSub(Subscription sub) async {
    final nodes = sub.nodes.where((n) => n.supported).toList();
    _set({for (final n in nodes) n.id: pending});
    final v = ref.read(vpnProvider);
    final viaCore = v.status == VpnStatus.connected && v.tags.isNotEmpty;
    final api = viaCore ? ClashApi(v.apiPort, v.secret) : null;
    var idx = 0;
    Future<void> worker() async {
      while (idx < nodes.length) {
        final n = nodes[idx++];
        int r;
        if (api != null) {
          final tag = v.tags[n.id];
          r = tag == null ? fail : (await api.delay(tag) ?? fail);
        } else if (n.isUdp) {
          r = udp; // TCP handshake is meaningless for UDP protocols; connect the tunnel for a real URL-test
        } else {
          r = await measureRealPing(n.server, n.port) ?? fail;
        }
        _set({n.id: r});
      }
    }

    await Future.wait(List.generate(6, (_) => worker()));
  }
}

final pingProvider = NotifierProvider<PingNotifier, Map<String, int>>(PingNotifier.new);
