import 'dart:convert';

class WaveException implements Exception {
  final String message;
  WaveException(this.message);
  @override
  String toString() => message;
}

enum RouteMode { smart, global, perApp }

enum PerAppMode { allow, deny }

String stableHash(String s) {
  var a = 0x811c9dc5, b = 0x1b873593;
  for (final c in s.codeUnits) {
    a = ((a ^ c) * 0x01000193) & 0xFFFFFFFF;
    b = (((b + c) * 0x85ebca6b) ^ (b >> 13)) & 0xFFFFFFFF;
  }
  return a.toRadixString(16).padLeft(8, '0') + b.toRadixString(16).padLeft(8, '0');
}

class ProxyNode {
  final String id;
  final String name;
  final String type;
  final String server;
  final int port;
  final Map<String, dynamic> outbound; // sing-box outbound without "tag"
  final bool supported;
  final String? reason;

  const ProxyNode({
    required this.id,
    required this.name,
    required this.type,
    required this.server,
    required this.port,
    required this.outbound,
    required this.supported,
    this.reason,
  });

  factory ProxyNode.fromOutbound(String name, Map<String, dynamic> ob) => ProxyNode(
        id: stableHash(jsonEncode(ob)),
        name: name,
        type: '${ob['type']}',
        server: '${ob['server']}',
        port: (ob['server_port'] as num?)?.toInt() ?? 0,
        outbound: ob,
        supported: true,
      );

  factory ProxyNode.unsupported(String name, String type, String server, int port, String reason) => ProxyNode(
        id: stableHash('$type|$server|$port|$name|$reason'),
        name: name,
        type: type,
        server: server,
        port: port,
        outbound: <String, dynamic>{},
        supported: false,
        reason: reason,
      );

  bool get isUdp => const {'hysteria2', 'hysteria', 'tuic', 'wireguard'}.contains(type);

  String get badge {
    final tls = outbound['tls'];
    final reality = tls is Map && tls['reality'] is Map && tls['reality']['enabled'] == true;
    final tr = outbound['transport'] is Map ? '${outbound['transport']['type']}' : null;
    final base = const {
          'vless': 'VLESS',
          'vmess': 'VMess',
          'trojan': 'Trojan',
          'shadowsocks': 'Shadowsocks',
          'hysteria2': 'Hysteria2',
          'hysteria': 'Hysteria',
          'tuic': 'TUIC',
          'wireguard': 'WireGuard',
          'socks': 'SOCKS',
          'http': 'HTTP',
          'ssh': 'SSH',
        }[type] ??
        type.toUpperCase();
    if (reality) return '$base Reality';
    if (type == 'shadowsocks' && '${outbound['method']}'.startsWith('2022')) return 'Shadowsocks 2022';
    if (tr != null) return '$base ${tr.toUpperCase()}';
    if (tls is Map && tls['enabled'] == true && (type == 'vless' || type == 'vmess')) return '$base TLS';
    return base;
  }

  String get flag => RegExp('[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true).firstMatch(name)?.group(0) ?? '🌐';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'server': server,
        'port': port,
        'outbound': outbound,
        'supported': supported,
        'reason': reason,
      };

  factory ProxyNode.fromJson(Map<String, dynamic> j) => ProxyNode(
        id: j['id'] as String,
        name: j['name'] as String,
        type: j['type'] as String,
        server: j['server'] as String,
        port: (j['port'] as num).toInt(),
        outbound: Map<String, dynamic>.from(j['outbound'] as Map),
        supported: j['supported'] as bool,
        reason: j['reason'] as String?,
      );
}

class Subscription {
  final String id;
  final String name;
  final String? url;
  final List<ProxyNode> nodes;
  final int upload, download, total, expire; // bytes / unix seconds, 0 = unlimited
  final int intervalHours;
  final String? supportUrl, announce, webPage;
  final int updatedAt; // ms epoch

  const Subscription({
    required this.id,
    required this.name,
    required this.url,
    required this.nodes,
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
    this.intervalHours = 24,
    this.supportUrl,
    this.announce,
    this.webPage,
    required this.updatedAt,
  });

  int get used => upload + download;
  bool get unlimited => total <= 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire,
        'interval': intervalHours,
        'support': supportUrl,
        'announce': announce,
        'web': webPage,
        'updatedAt': updatedAt,
      };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: j['id'] as String,
        name: j['name'] as String,
        url: j['url'] as String?,
        nodes: (j['nodes'] as List).map((e) => ProxyNode.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
        upload: (j['upload'] as num?)?.toInt() ?? 0,
        download: (j['download'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        expire: (j['expire'] as num?)?.toInt() ?? 0,
        intervalHours: (j['interval'] as num?)?.toInt() ?? 24,
        supportUrl: j['support'] as String?,
        announce: j['announce'] as String?,
        webPage: j['web'] as String?,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );
}
