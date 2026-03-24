import '../models/vless_node.dart';

class VlessUriParser {
  static const Set<String> _handledKeys = <String>{
    'encryption',
    'flow',
    'type',
    'security',
    'sni',
    'servername',
    'fp',
    'pbk',
    'publickey',
    'sid',
    'shortid',
    'spx',
    'spiderx',
    'host',
    'path',
    'mode',
    'alpn',
  };

  VlessNode parse(String raw) {
    final link = raw.trim();
    if (link.isEmpty) {
      throw const FormatException('Empty link.');
    }

    final uri = Uri.parse(link);
    if (uri.scheme.toLowerCase() != 'vless') {
      throw FormatException('Unsupported scheme: ${uri.scheme}');
    }
    if (uri.userInfo.isEmpty) {
      throw const FormatException('Missing VLESS user id.');
    }
    if (uri.host.isEmpty) {
      throw const FormatException('Missing server host.');
    }
    if (uri.port <= 0) {
      throw const FormatException('Missing server port.');
    }

    final query = uri.queryParameters.map(
      (String key, String value) => MapEntry(key.toLowerCase(), value),
    );
    final network = _normalizeNetwork(query['type'] ?? 'tcp');
    final security = (query['security'] ?? 'none').trim();
    final serverName = (query['sni'] ?? query['servername'] ?? '').trim();
    final name = uri.fragment.isEmpty
        ? '${uri.host}:${uri.port}'
        : Uri.decodeComponent(uri.fragment).trim();

    final extras = <String, String>{};
    for (final entry in query.entries) {
      if (!_handledKeys.contains(entry.key)) {
        extras[entry.key] = entry.value;
      }
    }

    return VlessNode(
      name: name,
      address: uri.host.trim(),
      port: uri.port,
      id: Uri.decodeComponent(uri.userInfo).trim(),
      network: network,
      security: security,
      encryption: (query['encryption'] ?? 'none').trim(),
      flow: (query['flow'] ?? '').trim(),
      serverName: serverName,
      fingerprint: (query['fp'] ?? '').trim(),
      publicKey: (query['pbk'] ?? query['publickey'] ?? '').trim(),
      shortId: (query['sid'] ?? query['shortid'] ?? '').trim(),
      spiderX: (query['spx'] ?? query['spiderx'] ?? '').trim(),
      host: (query['host'] ?? '').trim(),
      path: (query['path'] ?? '').trim(),
      mode: (query['mode'] ?? '').trim(),
      alpn: _parseAlpn(query['alpn'] ?? ''),
      extras: extras,
    );
  }

  String encode(VlessNode node) {
    final Map<String, String> query = <String, String>{
      ...node.extras,
    };

    void putIfNotBlank(String key, String value) {
      final String normalized = value.trim();
      if (normalized.isNotEmpty) {
        query[key] = normalized;
      } else {
        query.remove(key);
      }
    }

    putIfNotBlank(
        'encryption', node.encryption.isEmpty ? 'none' : node.encryption);
    putIfNotBlank('flow', node.flow);
    putIfNotBlank('type', node.network);
    putIfNotBlank('security', node.security);
    putIfNotBlank('sni', node.serverName);
    putIfNotBlank('fp', node.fingerprint);
    putIfNotBlank('pbk', node.publicKey);
    putIfNotBlank('sid', node.shortId);
    putIfNotBlank('spx', node.spiderX);
    putIfNotBlank('host', node.host);
    putIfNotBlank('path', node.path);
    putIfNotBlank('mode', node.mode);
    putIfNotBlank('alpn', _encodeAlpn(node.alpn));

    return Uri(
      scheme: 'vless',
      userInfo: node.id.trim(),
      host: node.address.trim(),
      port: node.port,
      queryParameters: query.isEmpty ? null : query,
      fragment: node.name.trim().isEmpty ? null : node.name.trim(),
    ).toString();
  }

  String _normalizeNetwork(String value) {
    final lower = value.trim().toLowerCase();
    if (lower == 'splithttp') {
      return 'xhttp';
    }
    return lower.isEmpty ? 'tcp' : lower;
  }

  List<String> _parseAlpn(String value) {
    return value
        .split(',')
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toList();
  }

  String _encodeAlpn(List<String> values) {
    return values
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .join(',');
  }
}
