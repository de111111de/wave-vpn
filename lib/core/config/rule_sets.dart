import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class RuleSetPaths {
  final String? geosite, geoip;
  const RuleSetPaths(this.geosite, this.geoip);
}

/// Downloads sing-box binary rule-sets (.srs) to app storage so the core starts without network.
class RuleSets {
  static const _sources = {
    'geosite-category-ru.srs': [
      'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs',
      'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-category-ru.srs',
    ],
    'geoip-ru.srs': [
      'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs',
      'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-ru.srs',
    ],
  };

  static Future<RuleSetPaths> ensure() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/rulesets');
    await dir.create(recursive: true);
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 20)));

    Future<String?> one(String file) async {
      final f = File('${dir.path}/$file');
      if (await f.exists() && DateTime.now().difference(await f.lastModified()) < const Duration(days: 3)) return f.path;
      for (final u in _sources[file]!) {
        try {
          final r = await dio.get<List<int>>(u, options: Options(responseType: ResponseType.bytes));
          final d = r.data;
          // .srs magic: "SRS"
          if (r.statusCode == 200 && d != null && d.length > 16 && d[0] == 0x53 && d[1] == 0x52 && d[2] == 0x53) {
            await f.writeAsBytes(d, flush: true);
            return f.path;
          }
        } catch (_) {}
      }
      return await f.exists() ? f.path : null;
    }

    final r = await Future.wait([one('geosite-category-ru.srs'), one('geoip-ru.srs')]);
    return RuleSetPaths(r[0], r[1]);
  }
}
