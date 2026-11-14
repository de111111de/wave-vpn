import 'dart:typed_data';

import 'package:flutter/services.dart';

class AppInfo {
  final String name, package;
  final bool system;
  const AppInfo(this.name, this.package, this.system);
}

class VpnChannel {
  static const _m = MethodChannel('com.wave.vpn/core');
  static const _e = EventChannel('com.wave.vpn/stats');

  static Stream<Map<String, dynamic>> get events =>
      _e.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map));

  static Future<bool> prepare() async => (await _m.invokeMethod<bool>('prepare')) ?? false;

  static Future<void> start({required String config, required int apiPort, required String secret}) =>
      _m.invokeMethod('start', {'config': config, 'apiPort': apiPort, 'secret': secret});

  static Future<void> stop() => _m.invokeMethod('stop');

  static Future<void> requestNotifications() => _m.invokeMethod('requestNotifications');

  static Future<String> logs() async => (await _m.invokeMethod<String>('logs')) ?? '';

  static Future<String?> initialLink() => _m.invokeMethod<String>('initialLink');

  static void onLink(void Function(String link) cb) {
    _m.setMethodCallHandler((call) async {
      if (call.method == 'onLink' && call.arguments is String) cb(call.arguments as String);
    });
  }

  static Future<List<AppInfo>> installedApps() async {
    final r = await _m.invokeMethod<List<dynamic>>('installedApps') ?? [];
    return r.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return AppInfo(m['name'] as String, m['package'] as String, m['system'] as bool);
    }).toList();
  }

  static Future<Uint8List?> appIcon(String pkg) => _m.invokeMethod<Uint8List>('appIcon', {'package': pkg});
}
