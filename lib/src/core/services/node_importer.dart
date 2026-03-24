import 'dart:convert';

import '../models/vless_node.dart';
import '../models/xhttp_download_settings.dart';
import 'vless_uri_parser.dart';

class NodeImporter {
  NodeImporter({
    VlessUriParser? uriParser,
  }) : _uriParser = uriParser ?? VlessUriParser();

  final VlessUriParser _uriParser;

  VlessNode parseNode(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) {
      throw const FormatException('没有可导入的内容。');
    }
    if (text.toLowerCase().startsWith('vless://')) {
      return _uriParser.parse(text);
    }

    final Map<String, dynamic> json = _parseJsonObject(text);
    if (_looksLikeOutbound(json)) {
      return _parseOutbound(json);
    }
    if (_looksLikePatch(json)) {
      throw const FormatException('这是 split patch JSON，请对已有节点应用补丁。');
    }
    throw const FormatException(
        '暂不支持这类导入内容。请粘贴 vless:// 或 client_outbound.json。');
  }

  VlessNode applyPatch(VlessNode baseNode, String raw) {
    final String text = raw.trim();
    if (text.isEmpty) {
      throw const FormatException('没有可应用的补丁内容。');
    }

    final Map<String, dynamic> json = _parseJsonObject(text);
    if (!_looksLikePatch(json)) {
      throw const FormatException('补丁内容缺少 downloadSettings。');
    }

    final Map<String, dynamic> downloadJson =
        _asMap(json['downloadSettings'], fieldName: 'downloadSettings');

    return baseNode.copyWith(
      downloadSettings: _parseDownloadSettings(downloadJson),
    );
  }

  bool looksLikePatch(String raw) {
    final String text = raw.trim();
    if (text.isEmpty || text.toLowerCase().startsWith('vless://')) {
      return false;
    }

    try {
      final Map<String, dynamic> json = _parseJsonObject(text);
      return _looksLikePatch(json);
    } catch (_) {
      return false;
    }
  }

  VlessNode _parseOutbound(Map<String, dynamic> json) {
    final Map<String, dynamic> settings =
        _asMap(json['settings'], fieldName: 'settings');
    final List<dynamic> rawVnext =
        _asList(settings['vnext'], fieldName: 'settings.vnext');
    if (rawVnext.isEmpty) {
      throw const FormatException('VLESS outbound 缺少 vnext。');
    }

    final Map<String, dynamic> endpoint =
        _asMap(rawVnext.first, fieldName: 'settings.vnext[0]');
    final List<dynamic> rawUsers =
        _asList(endpoint['users'], fieldName: 'settings.vnext[0].users');
    if (rawUsers.isEmpty) {
      throw const FormatException('VLESS outbound 缺少 users。');
    }

    final Map<String, dynamic> user =
        _asMap(rawUsers.first, fieldName: 'settings.vnext[0].users[0]');
    final Map<String, dynamic> streamSettings =
        _asMap(json['streamSettings'], fieldName: 'streamSettings');
    final Map<String, dynamic> xhttpSettings =
        _pickXhttpSettings(streamSettings);

    final String security =
        _asString(streamSettings['security'], fallback: 'none');
    final Map<String, dynamic> realitySettings =
        _asMapOrEmpty(streamSettings['realitySettings']);
    final Map<String, dynamic> tlsSettings =
        _asMapOrEmpty(streamSettings['tlsSettings']);

    return VlessNode(
      name: _asString(json['tag'], fallback: '').trim().isEmpty
          ? '${_asString(endpoint['address'])}:${_asInt(endpoint['port'], fallback: 443)}'
          : _asString(json['tag']).trim(),
      address: _asString(endpoint['address']),
      port: _asInt(endpoint['port'], fallback: 443),
      id: _asString(user['id']),
      network: _asString(streamSettings['network'], fallback: 'tcp'),
      security: security,
      encryption: _asString(user['encryption'], fallback: 'none'),
      flow: _asString(user['flow'], fallback: ''),
      serverName: _resolveServerName(
        security: security,
        realitySettings: realitySettings,
        tlsSettings: tlsSettings,
      ),
      fingerprint: _resolveFingerprint(
        security: security,
        realitySettings: realitySettings,
        tlsSettings: tlsSettings,
      ),
      publicKey: _asString(realitySettings['publicKey'], fallback: ''),
      shortId: _asString(realitySettings['shortId'], fallback: ''),
      spiderX: _asString(realitySettings['spiderX'], fallback: ''),
      host: _asString(xhttpSettings['host'], fallback: ''),
      path: _asString(xhttpSettings['path'], fallback: ''),
      mode: _asString(xhttpSettings['mode'], fallback: ''),
      alpn: _parseStringList(tlsSettings['alpn']),
      downloadSettings: xhttpSettings.containsKey('downloadSettings')
          ? _parseDownloadSettings(
              _asMap(xhttpSettings['downloadSettings'],
                  fieldName: 'xhttpSettings.downloadSettings'),
            )
          : null,
    );
  }

  XhttpDownloadSettings _parseDownloadSettings(Map<String, dynamic> json) {
    final String security = _asString(json['security'], fallback: 'none');
    final Map<String, dynamic> realitySettings =
        _asMapOrEmpty(json['realitySettings']);
    final Map<String, dynamic> tlsSettings = _asMapOrEmpty(json['tlsSettings']);
    final Map<String, dynamic> xhttpSettings = _pickXhttpSettings(json);

    return XhttpDownloadSettings(
      address: _asString(json['address']),
      port: _asInt(json['port'], fallback: 443),
      network: _asString(json['network'], fallback: 'xhttp'),
      security: security,
      serverName: _resolveServerName(
        security: security,
        realitySettings: realitySettings,
        tlsSettings: tlsSettings,
      ),
      fingerprint: _resolveFingerprint(
        security: security,
        realitySettings: realitySettings,
        tlsSettings: tlsSettings,
      ),
      publicKey: _asString(realitySettings['publicKey'], fallback: ''),
      shortId: _asString(realitySettings['shortId'], fallback: ''),
      spiderX: _asString(realitySettings['spiderX'], fallback: ''),
      host: _asString(xhttpSettings['host'], fallback: ''),
      path: _asString(xhttpSettings['path'], fallback: ''),
      mode: _asString(xhttpSettings['mode'], fallback: ''),
      alpn: _parseStringList(tlsSettings['alpn']),
    );
  }

  Map<String, dynamic> _pickXhttpSettings(Map<String, dynamic> json) {
    if (json['xhttpSettings'] != null) {
      return _asMap(json['xhttpSettings'], fieldName: 'xhttpSettings');
    }
    if (json['splithttpSettings'] != null) {
      return _asMap(json['splithttpSettings'], fieldName: 'splithttpSettings');
    }
    return <String, dynamic>{};
  }

  bool _looksLikeOutbound(Map<String, dynamic> json) {
    return _asString(json['protocol'], fallback: '').toLowerCase() == 'vless' &&
        json['settings'] is Map<String, dynamic>;
  }

  bool _looksLikePatch(Map<String, dynamic> json) {
    return json['downloadSettings'] is Map<String, dynamic>;
  }

  Map<String, dynamic> _parseJsonObject(String raw) {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('导入内容必须是 JSON 对象。');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Map<String, dynamic> _asMap(
    dynamic value, {
    required String fieldName,
  }) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    throw FormatException('$fieldName 必须是对象。');
  }

  Map<String, dynamic> _asMapOrEmpty(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return <String, dynamic>{};
  }

  List<dynamic> _asList(
    dynamic value, {
    required String fieldName,
  }) {
    if (value is List) {
      return value;
    }
    throw FormatException('$fieldName 必须是数组。');
  }

  String _asString(dynamic value, {String fallback = ''}) {
    final String normalized = value?.toString() ?? fallback;
    return normalized.trim().isEmpty ? fallback : normalized.trim();
  }

  int _asInt(dynamic value, {required int fallback}) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim()) ?? fallback;
    }
    return fallback;
  }

  String _resolveServerName({
    required String security,
    required Map<String, dynamic> realitySettings,
    required Map<String, dynamic> tlsSettings,
  }) {
    if (security.toLowerCase() == 'reality') {
      return _asString(realitySettings['serverName'], fallback: '');
    }
    if (security.toLowerCase() == 'tls') {
      return _asString(tlsSettings['serverName'], fallback: '');
    }
    return '';
  }

  String _resolveFingerprint({
    required String security,
    required Map<String, dynamic> realitySettings,
    required Map<String, dynamic> tlsSettings,
  }) {
    if (security.toLowerCase() == 'reality') {
      return _asString(realitySettings['fingerprint'], fallback: '');
    }
    if (security.toLowerCase() == 'tls') {
      return _asString(tlsSettings['fingerprint'], fallback: '');
    }
    return '';
  }

  List<String> _parseStringList(dynamic value) {
    if (value is List) {
      return value
          .map((dynamic item) => item.toString().trim())
          .where((String item) => item.isNotEmpty)
          .toList();
    }
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((String item) => item.trim())
          .where((String item) => item.isNotEmpty)
          .toList();
    }
    return <String>[];
  }
}
