import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:yaml/yaml.dart';

import '../models.dart';

// ───────────────────────── helpers ─────────────────────────

String _dec(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

String _decQ(String s) {
  try {
    return Uri.decodeQueryComponent(s);
  } catch (_) {
    return s;
  }
}

String? _nz(String? s) => (s == null || s.isEmpty) ? null : s;
String _s(dynamic v) => v == null ? '' : '$v';
int _int(dynamic v, [int d = 0]) => v is num ? v.toInt() : (int.tryParse('$v') ?? d);
Map<String, dynamic> _m(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List _l(dynamic v) => v is List ? v : const [];

bool _truthy(String? s) {
  final v = (s ?? '').toLowerCase();
  return v == '1' || v == 'true' || v == 'yes';
}

List<String> _list(String? s) => (s ?? '').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

String _b64(String s) {
  var t = s.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
  if (t.length % 4 == 1) throw const FormatException('bad base64');
  t += '=' * ((4 - t.length % 4) % 4);
  return utf8.decode(base64.decode(t), allowMalformed: true);
}

String? _tryB64(String s) {
  try {
    return _b64(s);
  } catch (_) {
    return null;
  }
}

bool _looksB64(String s) => RegExp(r'^[A-Za-z0-9+/_\-=\s]+$').hasMatch(s);

class _Unsupported implements Exception {
  final String reason;
  _Unsupported(this.reason);
}

ProxyNode _guard(String name, String type, String server, int port, Map<String, dynamic> Function() f) {
  final n = name.isEmpty ? '$server:$port' : name;
  try {
    return ProxyNode.fromOutbound(n, f());
  } on _Unsupported catch (e) {
    return ProxyNode.unsupported(n, type, server, port, e.reason);
  }
}

// ───────────────────────── deep-links ─────────────────────────

class ImportTarget {
  final String? url; // https:// subscription url
  final String? body; // inline payload (uri list / base64 / json / yaml)
  final String? name;
  const ImportTarget({this.url, this.body, this.name});
}

class LinkParser {
  static const _proxySchemes = 'vless|vmess|trojan|ss|hy2|hysteria2|hysteria|tuic|wg|wireguard';
  static final _proxyRe = RegExp('^($_proxySchemes)://', caseSensitive: false);
  static final _cmdRe = RegExp(
      r'^(add|import|install-config|import-remote-profile|install|subscribe|subscription|sub|config|crypt\d*)(?=[/?#]|$)',
      caseSensitive: false);

  /// wave:// happ:// incy:// v2raytun:// streisand:// clash:// hiddify:// sing-box:// + plain https:// / proxy URIs / base64.
  static ImportTarget parse(String input) {
    final s = input.trim();
    if (s.isEmpty) throw WaveException('Пустая ссылка');
    final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*)://').firstMatch(s);
    if (m == null) return _payload(s, null);
    final scheme = m.group(1)!.toLowerCase();
    if (scheme == 'http' || scheme == 'https') return _payload(s, null);
    if (_proxyRe.hasMatch(s)) return ImportTarget(body: s);

    var rest = s.substring(m.end);
    final cm = _cmdRe.firstMatch(rest);
    if (cm != null) {
      if (cm.group(1)!.toLowerCase().startsWith('crypt')) {
        throw WaveException('Ссылка happ://crypt… зашифрована ключом Happ и локально не расшифровывается. Нужна обычная https:// ссылка подписки.');
      }
      rest = rest.substring(cm.end);
    }
    if (rest.startsWith('/')) rest = rest.substring(1);

    if (rest.startsWith('?')) {
      var q = rest.substring(1);
      String? name;
      final h = q.indexOf('#');
      if (h >= 0) {
        name = _dec(q.substring(h + 1));
        q = q.substring(0, h);
      }
      final params = <String, String>{};
      for (final p in q.split('&')) {
        final i = p.indexOf('=');
        if (i > 0) params[p.substring(0, i).toLowerCase()] = _decQ(p.substring(i + 1));
      }
      final u = params['url'] ?? params['link'] ?? params['sub'] ?? params['subscription'] ?? params['config'];
      if (u == null) throw WaveException('В ссылке нет параметра url');
      return _payload(u, name ?? params['name'] ?? params['remarks']);
    }
    return _payload(rest, null);
  }

  static ImportTarget _payload(String p, String? name) {
    var s = p.trim();
    if (RegExp(r'^https?%3A', caseSensitive: false).hasMatch(s)) s = _dec(s);
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(s)) {
      final h = s.indexOf('#');
      if (h >= 0) {
        name ??= _dec(s.substring(h + 1));
        s = s.substring(0, h);
      }
      return ImportTarget(url: s, name: _nz(name));
    }
    if (_proxyRe.hasMatch(s) || s.startsWith('{') || s.startsWith('[') || s.contains('\n')) {
      return ImportTarget(body: s, name: name);
    }
    var b = s;
    final h = b.indexOf('#');
    if (h >= 0) {
      name ??= _dec(b.substring(h + 1));
      b = b.substring(0, h);
    }
    final d = _looksB64(b) ? _tryB64(b) : null;
    if (d != null) {
      final t = d.trim();
      if (RegExp(r'^https?://', caseSensitive: false).hasMatch(t)) return ImportTarget(url: t, name: _nz(name));
      return ImportTarget(body: t, name: _nz(name));
    }
    throw WaveException('Не удалось распознать ссылку или подписку');
  }
}

// ───────────────────────── fetcher ─────────────────────────

class SubscriptionMeta {
  final String? title, supportUrl, announce, webPage;
  final int upload, download, total, expire, updateHours;
  const SubscriptionMeta({
    this.title,
    this.supportUrl,
    this.announce,
    this.webPage,
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
    this.updateHours = 24,
  });
}

class FetchedBody {
  final String body;
  final SubscriptionMeta meta;
  FetchedBody(this.body, this.meta);
}

class SubscriptionFetcher {
  static const defaultUserAgent = 'Wave/1.0 (Happ/Incy compatible; Sing-box)';
  final Dio _dio;

  SubscriptionFetcher([Dio? dio])
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 30)));

  Future<FetchedBody> fetch(String url, {String? userAgent}) async {
    final Response<List<int>> res;
    try {
      res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (_) => true,
          headers: {'User-Agent': (userAgent == null || userAgent.trim().isEmpty) ? defaultUserAgent : userAgent, 'Accept': '*/*'},
        ),
      );
    } on DioException catch (e) {
      throw WaveException('Сеть: ${e.message ?? e.type.name}');
    }
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 300) throw WaveException('Сервер подписки ответил HTTP $code');
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(', '));
    return FetchedBody(utf8.decode(res.data ?? const [], allowMalformed: true), parseHeaders(h, url));
  }

  static String? _headerText(String? v) {
    if (v == null) return null;
    var t = v.trim();
    if (t.isEmpty) return null;
    if (t.toLowerCase().startsWith('base64:')) return _nz(_tryB64(t.substring(7)));
    if (t.contains('%')) t = _dec(t);
    if (t.length > 1 && t.startsWith('"') && t.endsWith('"')) t = t.substring(1, t.length - 1);
    return _nz(t);
  }

  static SubscriptionMeta parseHeaders(Map<String, String> h, String url) {
    final ui = h['subscription-userinfo'] ?? '';
    int g(String k) {
      final m = RegExp('$k=(\\d+)', caseSensitive: false).firstMatch(ui);
      return m == null ? 0 : int.parse(m.group(1)!);
    }

    String? title = _headerText(h['profile-title']);
    if (title == null) {
      final cd = h['content-disposition'] ?? '';
      final m = RegExp(r"filename\*=(?:UTF-8'')?([^;]+)", caseSensitive: false).firstMatch(cd) ??
          RegExp(r'filename="?([^";]+)"?', caseSensitive: false).firstMatch(cd);
      if (m != null) title = _nz(_dec(m.group(1)!.trim()));
    }
    return SubscriptionMeta(
      title: title,
      supportUrl: _nz(h['support-url']),
      announce: _headerText(h['announce']),
      webPage: _nz(h['profile-web-page-url']),
      upload: g('upload'),
      download: g('download'),
      total: g('total'),
      expire: g('expire'),
      updateHours: int.tryParse((h['profile-update-interval'] ?? '').trim()) ?? 24,
    );
  }
}

// ───────────────────────── raw uri ─────────────────────────

class _Uri {
  final String scheme, userInfo, host, fragment;
  final int? port;
  final Map<String, String> q; // lower-cased keys
  _Uri(this.scheme, this.userInfo, this.host, this.port, this.q, this.fragment);

  static _Uri? parse(String s) {
    final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*)://(.*)$', dotAll: true).firstMatch(s.trim());
    if (m == null) return null;
    var rest = m.group(2)!;
    var frag = '';
    final hi = rest.indexOf('#');
    if (hi >= 0) {
      frag = _dec(rest.substring(hi + 1));
      rest = rest.substring(0, hi);
    }
    final q = <String, String>{};
    final qi = rest.indexOf('?');
    if (qi >= 0) {
      for (final p in rest.substring(qi + 1).split('&')) {
        if (p.isEmpty) continue;
        final i = p.indexOf('=');
        q[(i < 0 ? p : p.substring(0, i)).toLowerCase()] = i < 0 ? '' : _decQ(p.substring(i + 1));
      }
      rest = rest.substring(0, qi);
    }
    final si = rest.indexOf('/');
    final auth = si >= 0 ? rest.substring(0, si) : rest;
    final at = auth.lastIndexOf('@');
    final ui = at >= 0 ? auth.substring(0, at) : '';
    final hp = at >= 0 ? auth.substring(at + 1) : auth;
    String host;
    int? port;
    if (hp.startsWith('[')) {
      final e = hp.indexOf(']');
      host = hp.substring(1, e < 0 ? hp.length : e);
      final r = e < 0 ? '' : hp.substring(e + 1);
      port = r.startsWith(':') ? _port(r.substring(1)) : null;
    } else {
      final c = hp.lastIndexOf(':');
      if (c >= 0) {
        host = hp.substring(0, c);
        port = _port(hp.substring(c + 1));
      } else {
        host = hp;
      }
    }
    if (host.isEmpty) return null;
    return _Uri(m.group(1)!.toLowerCase(), ui, host, port, q, frag);
  }

  static int? _port(String s) {
    final m = RegExp(r'^\d+').firstMatch(s);
    return m == null ? null : int.parse(m.group(0)!);
  }

  String get name => fragment.isNotEmpty ? fragment : '$host:${port ?? ''}';

  String? get(List<String> keys) {
    for (final k in keys) {
      final v = q[k];
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }
}

// ───────────────────────── tls / transport ─────────────────────────

Map<String, dynamic>? _tls(String security, String? sni, String? fp, String? alpn, bool insecure, String? pbk, String? sid) {
  final sec = security.toLowerCase();
  if (sec != 'tls' && sec != 'reality' && sec != 'xtls') return null;
  final t = <String, dynamic>{'enabled': true};
  if (sni != null && sni.isNotEmpty) t['server_name'] = sni;
  if (insecure) t['insecure'] = true;
  final al = _list(alpn);
  if (al.isNotEmpty) t['alpn'] = al;
  final f = (fp == null || fp.isEmpty || fp == 'none') ? null : fp;
  if (sec == 'reality') {
    if (pbk == null || pbk.isEmpty) throw const FormatException('reality: нет pbk');
    t['reality'] = {'enabled': true, 'public_key': pbk, 'short_id': sid ?? ''};
    t['utls'] = {'enabled': true, 'fingerprint': f ?? 'chrome'};
  } else if (f != null) {
    t['utls'] = {'enabled': true, 'fingerprint': f};
  }
  return t;
}

Map<String, dynamic>? _transport(String net, {String? host, String? path, String? serviceName, String? headerType}) {
  switch (net.toLowerCase()) {
    case '':
    case 'tcp':
    case 'raw':
      if (headerType == 'http') {
        return {'type': 'http', 'host': _list(host), 'path': (path == null || path.isEmpty) ? '/' : path.split(',').first, 'method': 'GET'};
      }
      return null;
    case 'ws':
      var p = (path == null || path.isEmpty) ? '/' : path;
      int? ed;
      final em = RegExp(r'[?&]ed=(\d+)').firstMatch(p);
      if (em != null) {
        ed = int.parse(em.group(1)!);
        p = p.replaceFirst(RegExp(r'[?&]ed=\d+'), '');
        if (p.contains('&') && !p.contains('?')) p = p.replaceFirst('&', '?');
        if (p.isEmpty) p = '/';
      }
      return {
        'type': 'ws',
        'path': p,
        if (host != null && host.isNotEmpty) 'headers': {'Host': host},
        if (ed != null) 'max_early_data': ed,
        if (ed != null) 'early_data_header_name': 'Sec-WebSocket-Protocol',
      };
    case 'grpc':
      return {'type': 'grpc', 'service_name': serviceName ?? path ?? ''};
    case 'httpupgrade':
      return {'type': 'httpupgrade', 'host': host ?? '', 'path': (path == null || path.isEmpty) ? '/' : path};
    case 'h2':
    case 'http':
      return {'type': 'http', 'host': _list(host), 'path': (path == null || path.isEmpty) ? '/' : path};
    case 'xhttp':
    case 'splithttp':
      throw _Unsupported('XHTTP не поддерживается ядром sing-box');
    default:
      throw _Unsupported('транспорт «$net» не поддерживается');
  }
}

// ───────────────────────── protocol parsers ─────────────────────────

class NodeParser {
  static ProxyNode? fromUri(String line) {
    final l = line.trim();
    final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*)://').firstMatch(l);
    if (m == null) return null;
    switch (m.group(1)!.toLowerCase()) {
      case 'vless':
        return _vless(_need(l));
      case 'vmess':
        return _vmess(l);
      case 'trojan':
        return _trojan(_need(l));
      case 'ss':
        return _ss(l);
      case 'hy2':
      case 'hysteria2':
        return _hy2(_need(l));
      case 'tuic':
        return _tuic(_need(l));
      case 'wg':
      case 'wireguard':
        return _wg(_need(l));
      default:
        return null;
    }
  }

  static _Uri _need(String l) => _Uri.parse(l) ?? (throw FormatException('bad uri: $l'));

  static ProxyNode _vless(_Uri u) {
    final q = u.q;
    final port = u.port ?? 443;
    return _guard(u.fragment, 'vless', u.host, port, () {
      final enc = q['encryption'];
      if (enc != null && enc.isNotEmpty && enc != 'none') throw _Unsupported('VLESS encryption не поддерживается');
      final sec = (q['security'] ?? 'none').toLowerCase();
      final net = (q['type'] ?? 'tcp').toLowerCase();
      final ob = <String, dynamic>{'type': 'vless', 'server': u.host, 'server_port': port, 'uuid': _dec(u.userInfo)};
      final flow = q['flow'];
      if (flow != null && flow.isNotEmpty && flow != 'none') ob['flow'] = flow;
      ob['packet_encoding'] = _nz(q['packetencoding']) ?? 'xudp';
      final tls = _tls(sec, q['sni'] ?? q['peer'] ?? (sec == 'tls' ? q['host'] : null), q['fp'], q['alpn'],
          _truthy(q['allowinsecure'] ?? q['insecure']), q['pbk'], q['sid']);
      if (tls != null) ob['tls'] = tls;
      final tr = _transport(net, host: q['host'], path: q['path'], serviceName: q['servicename'], headerType: q['headertype']);
      if (tr != null) ob['transport'] = tr;
      return ob;
    });
  }

  static ProxyNode _vmess(String raw) {
    var body = raw.substring(8);
    var frag = '';
    final hi = body.indexOf('#');
    if (hi >= 0) {
      frag = _dec(body.substring(hi + 1));
      body = body.substring(0, hi);
    }
    if (body.contains('@')) {
      final u = _need(raw);
      final q = u.q;
      final port = u.port ?? 443;
      return _guard(u.fragment, 'vmess', u.host, port, () {
        final sec = (q['security'] ?? 'none').toLowerCase();
        final ob = <String, dynamic>{
          'type': 'vmess',
          'server': u.host,
          'server_port': port,
          'uuid': _dec(u.userInfo),
          'security': _nz(q['encryption']) ?? 'auto',
          'alter_id': 0,
          'packet_encoding': 'xudp',
        };
        final tls = _tls(sec, q['sni'] ?? q['peer'], q['fp'], q['alpn'], _truthy(q['allowinsecure'] ?? q['insecure']), q['pbk'], q['sid']);
        if (tls != null) ob['tls'] = tls;
        final tr = _transport((q['type'] ?? 'tcp'), host: q['host'], path: q['path'], serviceName: q['servicename'], headerType: q['headertype']);
        if (tr != null) ob['transport'] = tr;
        return ob;
      });
    }
    final j = _m(jsonDecode(_b64(body)));
    final server = _s(j['add']);
    final port = _int(j['port'], 443);
    final name = _nz(_s(j['ps'])) ?? frag;
    return _guard(name, 'vmess', server, port, () {
      final net = _s(j['net']).isEmpty ? 'tcp' : _s(j['net']).toLowerCase();
      final host = _nz(_s(j['host']));
      final path = _nz(_s(j['path']));
      final ob = <String, dynamic>{
        'type': 'vmess',
        'server': server,
        'server_port': port,
        'uuid': _s(j['id']),
        'security': _nz(_s(j['scy'])) ?? 'auto',
        'alter_id': _int(j['aid']),
        'packet_encoding': 'xudp',
      };
      final sec = _s(j['tls']).toLowerCase();
      final tls = _tls(sec, _nz(_s(j['sni'])) ?? (sec == 'tls' ? host : null), _nz(_s(j['fp'])), _nz(_s(j['alpn'])),
          _truthy(_s(j['allowInsecure'])) || j['skip-cert-verify'] == true, null, null);
      if (tls != null) ob['tls'] = tls;
      final tr = _transport(net, host: host, path: path, serviceName: path, headerType: _s(j['type']));
      if (tr != null) ob['transport'] = tr;
      return ob;
    });
  }

  static ProxyNode _trojan(_Uri u) {
    final q = u.q;
    final port = u.port ?? 443;
    return _guard(u.fragment, 'trojan', u.host, port, () {
      final sec = (q['security'] ?? 'tls').toLowerCase();
      final ob = <String, dynamic>{'type': 'trojan', 'server': u.host, 'server_port': port, 'password': _dec(u.userInfo)};
      final tls = _tls(sec, q['sni'] ?? q['peer'], q['fp'], q['alpn'], _truthy(q['allowinsecure'] ?? q['insecure']), q['pbk'], q['sid']);
      if (tls != null) ob['tls'] = tls;
      final tr = _transport((q['type'] ?? 'tcp'), host: q['host'], path: q['path'], serviceName: q['servicename'], headerType: q['headertype']);
      if (tr != null) ob['transport'] = tr;
      return ob;
    });
  }

  static ProxyNode _ss(String raw) {
    var body = raw.substring(5);
    var name = '';
    final hi = body.indexOf('#');
    if (hi >= 0) {
      name = _dec(body.substring(hi + 1));
      body = body.substring(0, hi);
    }
    final q = <String, String>{};
    final qi = body.indexOf('?');
    if (qi >= 0) {
      for (final p in body.substring(qi + 1).split('&')) {
        final i = p.indexOf('=');
        if (i > 0) q[p.substring(0, i).toLowerCase()] = _decQ(p.substring(i + 1));
      }
      body = body.substring(0, qi);
    }
    if (body.endsWith('/')) body = body.substring(0, body.length - 1);

    String cred, hp;
    final at = body.lastIndexOf('@');
    if (at >= 0) {
      final ui = body.substring(0, at);
      hp = body.substring(at + 1);
      cred = ui.contains(':') ? _dec(ui) : _b64(_dec(ui));
    } else {
      final d = _b64(_dec(body));
      final a = d.lastIndexOf('@');
      if (a < 0) throw const FormatException('bad ss');
      cred = d.substring(0, a);
      hp = d.substring(a + 1);
    }
    final c = cred.indexOf(':');
    if (c < 0) throw const FormatException('bad ss cred');
    var method = cred.substring(0, c).toLowerCase();
    final password = cred.substring(c + 1);
    final u = _need('ss://$hp');
    final port = u.port ?? 8388;
    method = const {'chacha20-poly1305': 'chacha20-ietf-poly1305', 'xchacha20-poly1305': 'xchacha20-ietf-poly1305'}[method] ?? method;
    return _guard(name, 'shadowsocks', u.host, port, () {
      final ob = <String, dynamic>{'type': 'shadowsocks', 'server': u.host, 'server_port': port, 'method': method, 'password': password};
      final plugin = q['plugin'];
      if (plugin != null && plugin.isNotEmpty) {
        final i = plugin.indexOf(';');
        var pn = (i < 0 ? plugin : plugin.substring(0, i)).trim();
        final opts = i < 0 ? '' : plugin.substring(i + 1);
        if (pn == 'simple-obfs') pn = 'obfs-local';
        if (pn != 'obfs-local' && pn != 'v2ray-plugin') throw _Unsupported('SS plugin «$pn» не поддерживается');
        ob['plugin'] = pn;
        ob['plugin_opts'] = opts;
      }
      return ob;
    });
  }

  static ProxyNode _hy2(_Uri u) {
    final q = u.q;
    final port = u.port ?? 443;
    return _guard(u.fragment, 'hysteria2', u.host, port, () {
      final ob = <String, dynamic>{'type': 'hysteria2', 'server': u.host, 'server_port': port, 'password': _dec(u.userInfo)};
      int? mbps(String? v) {
        final m = RegExp(r'\d+').firstMatch(v ?? '');
        return m == null ? null : int.parse(m.group(0)!);
      }

      final up = mbps(u.get(['up_mbps', 'upmbps', 'up']));
      final dn = mbps(u.get(['down_mbps', 'downmbps', 'down']));
      if (up != null) ob['up_mbps'] = up;
      if (dn != null) ob['down_mbps'] = dn;
      final obfs = u.get(['obfs']);
      if (obfs != null && obfs != 'none') ob['obfs'] = {'type': obfs, 'password': u.get(['obfs-password', 'obfs_password']) ?? ''};
      final alpn = _list(q['alpn']);
      final sni = u.get(['sni']);
      ob['tls'] = {
        'enabled': true,
        if (sni != null) 'server_name': sni,
        if (_truthy(u.get(['insecure', 'allowinsecure']))) 'insecure': true,
        'alpn': alpn.isEmpty ? ['h3'] : alpn,
      };
      return ob;
    });
  }

  static ProxyNode _tuic(_Uri u) {
    final q = u.q;
    final port = u.port ?? 443;
    return _guard(u.fragment, 'tuic', u.host, port, () {
      final i = u.userInfo.indexOf(':');
      final uuid = _dec(i < 0 ? u.userInfo : u.userInfo.substring(0, i));
      final pwd = i < 0 ? '' : _dec(u.userInfo.substring(i + 1));
      final alpn = _list(q['alpn']);
      final sni = u.get(['sni']);
      return <String, dynamic>{
        'type': 'tuic',
        'server': u.host,
        'server_port': port,
        'uuid': uuid,
        'password': pwd,
        'congestion_control': u.get(['congestion_control', 'congestion-control', 'congestion']) ?? 'bbr',
        'udp_relay_mode': u.get(['udp_relay_mode', 'udp-relay-mode']) ?? 'native',
        'tls': {
          'enabled': true,
          if (sni != null) 'server_name': sni,
          if (_truthy(u.get(['allow_insecure', 'allowinsecure', 'insecure']))) 'insecure': true,
          'alpn': alpn.isEmpty ? ['h3'] : alpn,
        },
      };
    });
  }

  static List<int>? _reserved(String? s) {
    if (s == null || s.isEmpty) return null;
    final parts = s.split(',').map((e) => int.tryParse(e.trim())).toList();
    if (parts.length == 3 && !parts.contains(null)) return parts.cast<int>();
    try {
      final b = base64.decode(s.replaceAll('-', '+').replaceAll('_', '/').padRight((s.length + 3) ~/ 4 * 4, '='));
      return b.length == 3 ? b.toList() : null;
    } catch (_) {
      return null;
    }
  }

  static ProxyNode _wg(_Uri u) {
    final port = u.port ?? 51820;
    return _guard(u.fragment, 'wireguard', u.host, port, () {
      String fix(String? s) => (s ?? '').replaceAll(' ', '+');
      final priv = fix(_dec(u.userInfo));
      final pub = fix(u.get(['publickey', 'public_key', 'peer_public_key', 'pubkey']));
      if (priv.isEmpty || pub.isEmpty) throw const FormatException('wg: нет ключей');
      final addrs = _list(u.get(['address', 'ip', 'local_address', 'localaddress']))
          .map((a) => a.contains('/') ? a : (a.contains(':') ? '$a/128' : '$a/32'))
          .toList();
      if (addrs.isEmpty) throw const FormatException('wg: нет address');
      final ob = <String, dynamic>{
        'type': 'wireguard',
        'server': u.host,
        'server_port': port,
        'local_address': addrs,
        'private_key': priv,
        'peer_public_key': pub,
      };
      final psk = fix(u.get(['presharedkey', 'psk', 'pre_shared_key']));
      if (psk.isNotEmpty) ob['pre_shared_key'] = psk;
      final res = _reserved(u.get(['reserved']));
      if (res != null) ob['reserved'] = res;
      final mtu = int.tryParse(u.get(['mtu']) ?? '');
      if (mtu != null) ob['mtu'] = mtu;
      return ob;
    });
  }
}

// ───────────────────────── xray / clash conversion ─────────────────────────

ProxyNode _fromXray(Map<String, dynamic> o, String? remark) {
  final proto = _s(o['protocol']).toLowerCase();
  final st = _m(o['settings']);
  final ss = _m(o['streamSettings']);
  final name = remark ?? _s(o['tag']);
  String server = '';
  int port = 0;
  Map<String, dynamic> base;
  switch (proto) {
    case 'vless':
    case 'vmess':
      final v = _m(_l(st['vnext']).firstOrNull);
      final u = _m(_l(v['users']).firstOrNull);
      server = _s(v['address']);
      port = _int(v['port']);
      base = {'type': proto, 'server': server, 'server_port': port, 'uuid': _s(u['id']), 'packet_encoding': 'xudp'};
      if (proto == 'vless') {
        if (_s(u['flow']).isNotEmpty) base['flow'] = u['flow'];
      } else {
        base['security'] = _nz(_s(u['security'])) ?? 'auto';
        base['alter_id'] = _int(u['alterId']);
      }
      break;
    case 'trojan':
      final v = _m(_l(st['servers']).firstOrNull);
      server = _s(v['address']);
      port = _int(v['port']);
      base = {'type': 'trojan', 'server': server, 'server_port': port, 'password': _s(v['password'])};
      break;
    default:
      final v = _m(_l(st['servers']).firstOrNull);
      server = _s(v['address']);
      port = _int(v['port']);
      base = {'type': 'shadowsocks', 'server': server, 'server_port': port, 'method': _s(v['method']), 'password': _s(v['password'])};
  }
  final type = '${base['type']}';
  return _guard(name, type, server, port, () {
    if (proto == 'vless') {
      final u = _m(_l(_m(_l(st['vnext']).firstOrNull)['users']).firstOrNull);
      final enc = _s(u['encryption']);
      if (enc.isNotEmpty && enc != 'none') throw _Unsupported('VLESS encryption не поддерживается');
    }
    if (proto == 'shadowsocks') return base;
    final net = _nz(_s(ss['network'])) ?? 'tcp';
    final sec = _nz(_s(ss['security'])) ?? 'none';
    final rs = _m(ss['realitySettings']);
    final src = sec == 'reality' ? rs : _m(ss['tlsSettings']);
    final tls = _tls(sec, _nz(_s(src['serverName'])), _nz(_s(src['fingerprint'])), _l(src['alpn']).join(','),
        src['allowInsecure'] == true, _nz(_s(rs['publicKey'])), _nz(_s(rs['shortId'])));
    if (tls != null) base['tls'] = tls;
    final ws = _m(ss['wsSettings']), gr = _m(ss['grpcSettings']), hu = _m(ss['httpupgradeSettings']), h2 = _m(ss['httpSettings']);
    String? host, path, svc, ht;
    switch (net) {
      case 'ws':
        host = _nz(_s(ws['host'])) ?? _nz(_s(_m(ws['headers'])['Host']));
        path = _nz(_s(ws['path']));
        break;
      case 'grpc':
        svc = _nz(_s(gr['serviceName']));
        break;
      case 'httpupgrade':
        host = _nz(_s(hu['host']));
        path = _nz(_s(hu['path']));
        break;
      case 'h2':
      case 'http':
        host = _l(h2['host']).join(',');
        path = _nz(_s(h2['path']));
        break;
      case 'tcp':
      case 'raw':
        final hd = _m(_m(ss['tcpSettings'])['header']);
        if (_s(hd['type']) == 'http') {
          ht = 'http';
          final req = _m(hd['request']);
          path = _l(req['path']).map((e) => '$e').join(',');
          host = _l(_m(req['headers'])['Host']).map((e) => '$e').join(',');
        }
        break;
    }
    final tr = _transport(net, host: host, path: path, serviceName: svc, headerType: ht);
    if (tr != null) base['transport'] = tr;
    return base;
  });
}

Map<String, dynamic>? _clashTransport(Map<String, dynamic> p) {
  final net = _s(p['network']).toLowerCase();
  final ws = _m(p['ws-opts']), gr = _m(p['grpc-opts']), h2 = _m(p['h2-opts']), ht = _m(p['http-opts']);
  switch (net) {
    case 'ws':
      final up = ws['v2ray-http-upgrade'] == true;
      return _transport(up ? 'httpupgrade' : 'ws', host: _nz(_s(_m(ws['headers'])['Host'])), path: _nz(_s(ws['path'])));
    case 'grpc':
      return _transport('grpc', serviceName: _s(gr['grpc-service-name']));
    case 'h2':
      return _transport('h2', host: _l(h2['host']).join(','), path: _nz(_s(h2['path'])));
    case 'http':
      return _transport('tcp',
          headerType: 'http',
          host: _l(_m(ht['headers'])['Host']).map((e) => '$e').join(','),
          path: _l(ht['path']).map((e) => '$e').join(','));
    default:
      return _transport(net.isEmpty ? 'tcp' : net);
  }
}

ProxyNode? _fromClash(Map<String, dynamic> p) {
  final type = _s(p['type']).toLowerCase();
  final name = _s(p['name']);
  final server = _s(p['server']);
  final port = _int(p['port']);
  String sni() => _nz(_s(p['servername'])) ?? _nz(_s(p['sni'])) ?? '';
  String alpn() => _l(p['alpn']).join(',');
  bool insecure() => p['skip-cert-verify'] == true;
  return _guard(name, type, server, port, () {
    switch (type) {
      case 'ss':
        final ob = <String, dynamic>{
          'type': 'shadowsocks',
          'server': server,
          'server_port': port,
          'method': const {'chacha20-poly1305': 'chacha20-ietf-poly1305'}[_s(p['cipher'])] ?? _s(p['cipher']),
          'password': _s(p['password']),
        };
        final pl = _s(p['plugin']);
        if (pl.isNotEmpty) {
          if (pl != 'obfs' && pl != 'v2ray-plugin') throw _Unsupported('SS plugin «$pl» не поддерживается');
          final po = _m(p['plugin-opts']);
          ob['plugin'] = pl == 'obfs' ? 'obfs-local' : pl;
          ob['plugin_opts'] = pl == 'obfs'
              ? 'obfs=${_s(po['mode'])};obfs-host=${_s(po['host'])}'
              : [
                  'mode=${_s(po['mode']).isEmpty ? 'websocket' : _s(po['mode'])}',
                  if (po['tls'] == true) 'tls',
                  if (_s(po['host']).isNotEmpty) 'host=${_s(po['host'])}',
                  if (_s(po['path']).isNotEmpty) 'path=${_s(po['path'])}',
                ].join(';');
        }
        return ob;
      case 'vmess':
      case 'vless':
        final ob = <String, dynamic>{'type': type, 'server': server, 'server_port': port, 'uuid': _s(p['uuid']), 'packet_encoding': 'xudp'};
        if (type == 'vmess') {
          ob['security'] = _nz(_s(p['cipher'])) ?? 'auto';
          ob['alter_id'] = _int(p['alterId']);
        } else if (_s(p['flow']).isNotEmpty) {
          ob['flow'] = p['flow'];
        }
        final ro = _m(p['reality-opts']);
        final sec = ro.isNotEmpty ? 'reality' : (p['tls'] == true ? 'tls' : 'none');
        final tls = _tls(sec, _nz(sni()), _nz(_s(p['client-fingerprint'])), alpn(), insecure(), _nz(_s(ro['public-key'])), _nz(_s(ro['short-id'])));
        if (tls != null) ob['tls'] = tls;
        final tr = _clashTransport(p);
        if (tr != null) ob['transport'] = tr;
        return ob;
      case 'trojan':
        final ob = <String, dynamic>{'type': 'trojan', 'server': server, 'server_port': port, 'password': _s(p['password'])};
        final tls = _tls('tls', _nz(sni()), _nz(_s(p['client-fingerprint'])), alpn(), insecure(), null, null);
        if (tls != null) ob['tls'] = tls;
        final tr = _clashTransport(p);
        if (tr != null) ob['transport'] = tr;
        return ob;
      case 'hysteria2':
      case 'hy2':
        int? mb(dynamic v) {
          final m = RegExp(r'\d+').firstMatch(_s(v));
          return m == null ? null : int.parse(m.group(0)!);
        }

        final al = _l(p['alpn']).map((e) => '$e').toList();
        return <String, dynamic>{
          'type': 'hysteria2',
          'server': server,
          'server_port': port,
          'password': _s(p['password']),
          if (mb(p['up']) != null) 'up_mbps': mb(p['up']),
          if (mb(p['down']) != null) 'down_mbps': mb(p['down']),
          if (_s(p['obfs']).isNotEmpty) 'obfs': {'type': _s(p['obfs']), 'password': _s(p['obfs-password'])},
          'tls': {
            'enabled': true,
            if (sni().isNotEmpty) 'server_name': sni(),
            if (insecure()) 'insecure': true,
            'alpn': al.isEmpty ? ['h3'] : al,
          },
        };
      case 'tuic':
        final al = _l(p['alpn']).map((e) => '$e').toList();
        return <String, dynamic>{
          'type': 'tuic',
          'server': server,
          'server_port': port,
          'uuid': _s(p['uuid']),
          'password': _s(p['password']),
          'congestion_control': _nz(_s(p['congestion-controller'])) ?? 'bbr',
          'udp_relay_mode': _nz(_s(p['udp-relay-mode'])) ?? 'native',
          'tls': {
            'enabled': true,
            if (sni().isNotEmpty) 'server_name': sni(),
            if (insecure()) 'insecure': true,
            'alpn': al.isEmpty ? ['h3'] : al,
          },
        };
      case 'wireguard':
        final addrs = [
          if (_s(p['ip']).isNotEmpty) _s(p['ip']).contains('/') ? _s(p['ip']) : '${_s(p['ip'])}/32',
          if (_s(p['ipv6']).isNotEmpty) _s(p['ipv6']).contains('/') ? _s(p['ipv6']) : '${_s(p['ipv6'])}/128',
        ];
        if (addrs.isEmpty) throw const FormatException('wg: нет ip');
        final res = p['reserved'] is List ? _l(p['reserved']).map((e) => _int(e)).toList() : NodeParser._reserved(_nz(_s(p['reserved'])));
        return <String, dynamic>{
          'type': 'wireguard',
          'server': server,
          'server_port': port,
          'local_address': addrs,
          'private_key': _s(p['private-key']),
          'peer_public_key': _s(p['public-key']),
          if (_s(p['pre-shared-key']).isNotEmpty) 'pre_shared_key': _s(p['pre-shared-key']),
          if (res != null && res.length == 3) 'reserved': res,
          if (p['mtu'] != null) 'mtu': _int(p['mtu']),
        };
      default:
        throw _Unsupported('протокол «$type» не поддерживается');
    }
  });
}

dynamic _plain(dynamic y) {
  if (y is YamlMap) return {for (final e in y.entries) '${e.key}': _plain(e.value)};
  if (y is YamlList) return y.map(_plain).toList();
  return y;
}

// ───────────────────────── body decoder ─────────────────────────

class ParseResult {
  final List<ProxyNode> nodes;
  final int skipped;
  ParseResult(this.nodes, this.skipped);
}

class SubscriptionDecoder {
  static const _singTypes = {'vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria2', 'hysteria', 'tuic', 'wireguard', 'socks', 'http', 'ssh'};

  /// raw URI list | Base64 / Base64Url | JSON (sing-box / xray) | YAML (Clash)
  static ParseResult decode(String raw, [int depth = 0]) {
    final s = raw.replaceFirst('\uFEFF', '').trim();
    if (s.isEmpty) throw WaveException('Подписка пуста');
    final nodes = <ProxyNode>[];
    final seen = <String>{};
    var skipped = 0;
    void add(ProxyNode? n) {
      if (n == null) {
        skipped++;
      } else if (seen.add(n.id)) {
        nodes.add(n);
      }
    }

    if (s.startsWith('{') || s.startsWith('[')) {
      dynamic j;
      try {
        j = jsonDecode(s);
      } on FormatException {
        throw WaveException('Некорректный JSON в подписке');
      }
      _walkJson(j, add);
    } else if (RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(s)) {
      final y = _plain(loadYaml(s));
      for (final e in _l(y is Map ? y['proxies'] : null)) {
        if (e is! Map) continue;
        try {
          add(_fromClash(Map<String, dynamic>.from(e)));
        } catch (_) {
          skipped++;
        }
      }
    } else if (s.contains('://')) {
      for (final line in const LineSplitter().convert(s)) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        try {
          add(NodeParser.fromUri(t));
        } catch (_) {
          skipped++;
        }
      }
    } else if (depth < 2 && _looksB64(s)) {
      final d = _tryB64(s);
      if (d == null) throw WaveException('Не удалось декодировать Base64 подписки');
      return decode(d, depth + 1);
    } else {
      throw WaveException('Не удалось определить формат подписки');
    }
    return ParseResult(nodes, skipped);
  }

  static void _walkJson(dynamic j, void Function(ProxyNode?) add) {
    if (j is List) {
      for (final e in j) {
        _walkJson(e, add);
      }
      return;
    }
    if (j is! Map) return;
    final m = Map<String, dynamic>.from(j);
    final outs = m['outbounds'];
    if (outs is List) {
      for (final o in outs) {
        if (o is Map) _one(Map<String, dynamic>.from(o), _nz(_s(m['remarks'])), add);
      }
      return;
    }
    if (m['type'] != null || m['protocol'] != null) _one(m, null, add);
  }

  static void _one(Map<String, dynamic> o, String? remark, void Function(ProxyNode?) add) {
    if (o['protocol'] != null) {
      if (!{'vless', 'vmess', 'trojan', 'shadowsocks'}.contains(_s(o['protocol']).toLowerCase())) return;
      try {
        add(_fromXray(o, remark));
      } catch (_) {
        add(null);
      }
      return;
    }
    if (!_singTypes.contains(_s(o['type']))) return;
    final ob = Map<String, dynamic>.from(o);
    final tag = _s(ob.remove('tag'));
    ob.remove('detour');
    add(ProxyNode.fromOutbound(remark ?? (tag.isEmpty ? '${ob['server']}:${ob['server_port']}' : tag), ob));
  }
}
