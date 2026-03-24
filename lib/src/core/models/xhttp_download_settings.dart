class XhttpDownloadSettings {
  const XhttpDownloadSettings({
    required this.address,
    required this.port,
    this.network = 'xhttp',
    this.security = 'reality',
    this.serverName = '',
    this.fingerprint = '',
    this.publicKey = '',
    this.shortId = '',
    this.spiderX = '',
    this.host = '',
    this.path = '',
    this.mode = '',
    this.alpn = const <String>[],
  });

  final String address;
  final int port;
  final String network;
  final String security;
  final String serverName;
  final String fingerprint;
  final String publicKey;
  final String shortId;
  final String spiderX;
  final String host;
  final String path;
  final String mode;
  final List<String> alpn;

  bool get isReality => security.toLowerCase() == 'reality';

  bool get isTls => security.toLowerCase() == 'tls';

  bool get isXhttp {
    final String value = network.toLowerCase();
    return value == 'xhttp' || value == 'splithttp';
  }

  XhttpDownloadSettings copyWith({
    String? address,
    int? port,
    String? network,
    String? security,
    String? serverName,
    String? fingerprint,
    String? publicKey,
    String? shortId,
    String? spiderX,
    String? host,
    String? path,
    String? mode,
    List<String>? alpn,
  }) {
    return XhttpDownloadSettings(
      address: address ?? this.address,
      port: port ?? this.port,
      network: network ?? this.network,
      security: security ?? this.security,
      serverName: serverName ?? this.serverName,
      fingerprint: fingerprint ?? this.fingerprint,
      publicKey: publicKey ?? this.publicKey,
      shortId: shortId ?? this.shortId,
      spiderX: spiderX ?? this.spiderX,
      host: host ?? this.host,
      path: path ?? this.path,
      mode: mode ?? this.mode,
      alpn: alpn ?? this.alpn,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'address': address,
      'port': port,
      'network': network,
      'security': security,
      'serverName': serverName,
      'fingerprint': fingerprint,
      'publicKey': publicKey,
      'shortId': shortId,
      'spiderX': spiderX,
      'host': host,
      'path': path,
      'mode': mode,
      'alpn': alpn,
    };
  }

  factory XhttpDownloadSettings.fromJson(Map<String, dynamic> json) {
    return XhttpDownloadSettings(
      address: json['address'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 443,
      network: json['network'] as String? ?? 'xhttp',
      security: json['security'] as String? ?? 'reality',
      serverName: json['serverName'] as String? ?? '',
      fingerprint: json['fingerprint'] as String? ?? '',
      publicKey: json['publicKey'] as String? ?? '',
      shortId: json['shortId'] as String? ?? '',
      spiderX: json['spiderX'] as String? ?? '',
      host: json['host'] as String? ?? '',
      path: json['path'] as String? ?? '',
      mode: json['mode'] as String? ?? '',
      alpn: _parseStringList(json['alpn']),
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
