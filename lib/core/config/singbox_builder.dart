import 'dart:convert';
import 'dart:math';

import '../models.dart';

class BuildInput {
  final List<ProxyNode> nodes;
  final String? selectedNodeId; // null = urltest "auto"
  final RouteMode mode;
  final PerAppMode perAppMode;
  final List<String> packages;
  final String? geositeRuPath; // local .srs, null = domain-suffix fallback only
  final String? geoipRuPath;

  const BuildInput({
    required this.nodes,
    required this.selectedNodeId,
    required this.mode,
    required this.perAppMode,
    required this.packages,
    this.geositeRuPath,
    this.geoipRuPath,
  });
}

class BuiltConfig {
  final String json;
  final int apiPort;
  final String secret;
  final Map<String, String> tagById;
  const BuiltConfig(this.json, this.apiPort, this.secret, this.tagById);
}

class SingboxBuilder {
  static const apiPort = 19090; // clash_api (traffic stream + per-node delay)
  static const mixedPort = 17890; // local mixed inbound for URL-test
  static const testUrl = 'http://cp.cloudflare.com/generate_204';
  static const ruSuffixes = ['.ru', '.рф', '.xn--p1ai', '.su'];

  static BuiltConfig build(BuildInput i) {
    final nodes = i.nodes.where((n) => n.supported).toList();
    if (nodes.isEmpty) throw WaveException('В подписке нет поддерживаемых нод');

    final rnd = Random.secure();
    final secret = List.generate(24, (_) => rnd.nextInt(16).toRadixString(16)).join();

    final used = <String>{'proxy', 'auto', 'direct', 'block', 'dns-out'};
    final tagById = <String, String>{};
    final nodeOuts = <Map<String, dynamic>>[];
    for (final n in nodes) {
      final base = n.name.trim().isEmpty ? '${n.server}:${n.port}' : n.name.trim();
      var tag = base;
      var k = 2;
      while (!used.add(tag)) {
        tag = '$base #$k';
        k++;
      }
      tagById[n.id] = tag;
      nodeOuts.add({...n.outbound, 'tag': tag});
    }
    final tags = nodeOuts.map((o) => o['tag'] as String).toList();
    final selected = i.selectedNodeId == null ? null : tagById[i.selectedNodeId];

    final smart = i.mode == RouteMode.smart;
    final hasGs = smart && i.geositeRuPath != null;
    final hasGi = smart && i.geoipRuPath != null;

    final ruMatch = <Map<String, dynamic>>[
      {'domain_suffix': ruSuffixes},
      if (hasGs) {'rule_set': ['geosite-category-ru']},
    ];
    Map<String, dynamic> ruRule(String key, String val) =>
        ruMatch.length == 1 ? {...ruMatch.first, key: val} : {'type': 'logical', 'mode': 'or', 'rules': ruMatch, key: val};

    final tun = <String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      'interface_name': 'wave0',
      'address': ['172.19.0.1/30'],
      'mtu': 9000,
      'auto_route': true,
      'strict_route': true,
      'stack': 'system',
      'sniff': true,
    };
    if (i.mode == RouteMode.perApp && i.packages.isNotEmpty) {
      tun[i.perAppMode == PerAppMode.allow ? 'include_package' : 'exclude_package'] = i.packages;
    }

    final config = <String, dynamic>{
      'log': {'level': 'info', 'timestamp': true},
      'dns': {
        'servers': [
          {'tag': 'dns-proxy', 'address': 'https://1.1.1.1/dns-query', 'detour': 'proxy'},
          {'tag': 'dns-direct', 'address': 'https://77.88.8.8/dns-query', 'detour': 'direct'},
          {'tag': 'dns-fake', 'address': 'fakeip'},
        ],
        'rules': [
          {'outbound': ['any'], 'server': 'dns-direct'},
          if (smart) ruRule('server', 'dns-direct'),
          {'query_type': ['A', 'AAAA'], 'server': 'dns-fake'},
        ],
        'fakeip': {'enabled': true, 'inet4_range': '198.18.0.0/15', 'inet6_range': 'fc00::/18'},
        'final': 'dns-proxy',
        'strategy': 'ipv4_only',
        'independent_cache': true,
      },
      'inbounds': [
        tun,
        {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': mixedPort, 'sniff': true},
      ],
      'outbounds': [
        {
          'type': 'selector',
          'tag': 'proxy',
          'outbounds': ['auto', ...tags],
          'default': selected ?? 'auto',
          'interrupt_exist_connections': true,
        },
        {'type': 'urltest', 'tag': 'auto', 'outbounds': tags, 'url': testUrl, 'interval': '10m', 'tolerance': 50},
        ...nodeOuts,
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
        {'type': 'dns', 'tag': 'dns-out'},
      ],
      'route': {
        'rules': [
          {'protocol': 'dns', 'outbound': 'dns-out'},
          {'port': [53], 'outbound': 'dns-out'},
          {'ip_is_private': true, 'outbound': 'direct'},
          if (smart) ruRule('outbound', 'direct'),
          if (hasGi) {'rule_set': ['geoip-ru'], 'outbound': 'direct'},
        ],
        'rule_set': [
          if (hasGs) {'tag': 'geosite-category-ru', 'type': 'local', 'format': 'binary', 'path': i.geositeRuPath},
          if (hasGi) {'tag': 'geoip-ru', 'type': 'local', 'format': 'binary', 'path': i.geoipRuPath},
        ],
        'final': 'proxy',
        'auto_detect_interface': true,
      },
      'experimental': {
        'cache_file': {'enabled': true, 'path': 'wave-cache.db', 'store_fakeip': true},
        'clash_api': {'external_controller': '127.0.0.1:$apiPort', 'secret': secret},
      },
    };
    return BuiltConfig(jsonEncode(config), apiPort, secret, tagById);
  }
}
