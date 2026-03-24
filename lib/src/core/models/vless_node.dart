import 'xhttp_download_settings.dart';

const Object _downloadSettingsUnset = Object();

class VlessNode {
  const VlessNode({
    required this.name,
    required this.address,
    required this.port,
    required this.id,
    required this.network,
    required this.security,
    this.encryption = 'none',
    this.flow = '',
    this.serverName = '',
    this.fingerprint = '',
    this.publicKey = '',
    this.shortId = '',
    this.spiderX = '',
    this.host = '',
    this.path = '',
    this.mode = '',
    this.alpn = const <String>[],
    this.downloadSettings,
    this.extras = const <String, String>{},
  });

  final String name;
  final String address;
  final int port;
  final String id;
  final String network;
  final String security;
  final String encryption;
  final String flow;
  final String serverName;
  final String fingerprint;
  final String publicKey;
  final String shortId;
  final String spiderX;
  final String host;
  final String path;
  final String mode;
  final List<String> alpn;
  final XhttpDownloadSettings? downloadSettings;
  final Map<String, String> extras;

  bool get isReality => security.toLowerCase() == 'reality';

  bool get isTls => security.toLowerCase() == 'tls';

  bool get isXhttp {
    final value = network.toLowerCase();
    return value == 'xhttp' || value == 'splithttp';
  }

  VlessNode copyWith({
    String? name,
    String? address,
    int? port,
    String? id,
    String? network,
    String? security,
    String? encryption,
    String? flow,
    String? serverName,
    String? fingerprint,
    String? publicKey,
    String? shortId,
    String? spiderX,
    String? host,
    String? path,
    String? mode,
    List<String>? alpn,
    Object? downloadSettings = _downloadSettingsUnset,
    Map<String, String>? extras,
  }) {
    return VlessNode(
      name: name ?? this.name,
      address: address ?? this.address,
      port: port ?? this.port,
      id: id ?? this.id,
      network: network ?? this.network,
      security: security ?? this.security,
      encryption: encryption ?? this.encryption,
      flow: flow ?? this.flow,
      serverName: serverName ?? this.serverName,
      fingerprint: fingerprint ?? this.fingerprint,
      publicKey: publicKey ?? this.publicKey,
      shortId: shortId ?? this.shortId,
      spiderX: spiderX ?? this.spiderX,
      host: host ?? this.host,
      path: path ?? this.path,
      mode: mode ?? this.mode,
      alpn: alpn ?? this.alpn,
      downloadSettings: downloadSettings == _downloadSettingsUnset
          ? this.downloadSettings
          : downloadSettings as XhttpDownloadSettings?,
      extras: extras ?? this.extras,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'address': address,
      'port': port,
      'id': id,
      'network': network,
      'security': security,
      'encryption': encryption,
      'flow': flow,
      'serverName': serverName,
      'fingerprint': fingerprint,
      'publicKey': publicKey,
      'shortId': shortId,
      'spiderX': spiderX,
      'host': host,
      'path': path,
      'mode': mode,
      'alpn': alpn,
      'downloadSettings': downloadSettings?.toJson(),
      'extras': extras,
    };
  }

  factory VlessNode.fromJson(Map<String, dynamic> json) {
    return VlessNode(
      name: json['name'] as String? ?? '',
      address: json['address'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 443,
      id: json['id'] as String? ?? '',
      network: json['network'] as String? ?? 'tcp',
      security: json['security'] as String? ?? 'none',
      encryption: json['encryption'] as String? ?? 'none',
      flow: json['flow'] as String? ?? '',
      serverName: json['serverName'] as String? ?? '',
      fingerprint: json['fingerprint'] as String? ?? '',
      publicKey: json['publicKey'] as String? ?? '',
      shortId: json['shortId'] as String? ?? '',
      spiderX: json['spiderX'] as String? ?? '',
      host: json['host'] as String? ?? '',
      path: json['path'] as String? ?? '',
      mode: json['mode'] as String? ?? '',
      alpn: _parseStringList(json['alpn']),
      downloadSettings: json['downloadSettings'] is Map
          ? XhttpDownloadSettings.fromJson(
              Map<String, dynamic>.from(
                json['downloadSettings'] as Map<dynamic, dynamic>,
              ),
            )
          : null,
      extras: json['extras'] is Map
          ? Map<String, String>.from(
              (json['extras'] as Map<dynamic, dynamic>).map(
                (dynamic key, dynamic value) =>
                    MapEntry(key.toString(), value.toString()),
              ),
            )
          : const <String, String>{},
    );
  }

  static List<String> _parseStringList(dynamic value) {
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
