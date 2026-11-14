import 'dart:io';

import 'package:dio/dio.dart';

import '../config/singbox_builder.dart';

/// TCP handshake time in ms, null on failure/timeout. Meaningful only while the tunnel is down.
Future<int?> measureRealPing(String host, int port, {Duration timeout = const Duration(seconds: 3)}) async {
  final sw = Stopwatch()..start();
  Socket? s;
  try {
    s = await Socket.connect(host, port, timeout: timeout);
    sw.stop();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return null;
  } finally {
    s?.destroy();
  }
}

/// HTTP URL-test through the local mixed inbound (tunnel must be active). Measures the currently selected route.
Future<int?> urlTestViaLocalProxy({int port = SingboxBuilder.mixedPort, String url = SingboxBuilder.testUrl}) async {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
  final sw = Stopwatch()..start();
  try {
    final req = await c.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 6));
    await res.drain<void>();
    sw.stop();
    return (res.statusCode == 204 || res.statusCode == 200) ? sw.elapsedMilliseconds : null;
  } catch (_) {
    return null;
  } finally {
    c.close(force: true);
  }
}

/// Per-node URL-test executed by the sing-box core itself (clash_api).
class ClashApi {
  final Dio _d;
  ClashApi(int port, String secret)
      : _d = Dio(BaseOptions(
          baseUrl: 'http://127.0.0.1:$port',
          headers: {'Authorization': 'Bearer $secret'},
          connectTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 8),
          validateStatus: (_) => true,
        ));

  Future<int?> delay(String tag, {String url = SingboxBuilder.testUrl}) async {
    try {
      final r = await _d.get('/proxies/${Uri.encodeComponent(tag)}/delay', queryParameters: {'url': url, 'timeout': 5000});
      if (r.statusCode == 200 && r.data is Map) return (r.data['delay'] as num?)?.toInt();
    } catch (_) {}
    return null;
  }
}
