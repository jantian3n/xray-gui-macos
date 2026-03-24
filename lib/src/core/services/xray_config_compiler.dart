import '../models/profile.dart';
import '../models/routing_preset.dart';
import '../models/runtime_mode.dart';
import '../models/vless_node.dart';
import '../models/xhttp_download_settings.dart';

class XrayConfigCompiler {
  Map<String, dynamic> compile(Profile profile) {
    _validateNode(profile.node);

    return <String, dynamic>{
      'log': <String, dynamic>{
        'loglevel': 'info',
      },
      'dns': _buildDns(profile.routingPreset),
      'inbounds': _buildInbounds(profile),
      'outbounds': _buildOutbounds(profile.node),
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'domainMatcher': 'mph',
        'rules': _buildRoutingRules(profile.routingPreset),
      },
    };
  }

  void _validateNode(VlessNode node) {
    _validateSecurity(
      label: 'Upload',
      security: node.security,
      serverName: node.serverName,
      fingerprint: node.fingerprint,
      publicKey: node.publicKey,
    );

    final String network = node.network.toLowerCase();
    if ((network == 'xhttp' || network == 'splithttp') && node.path.isEmpty) {
      throw const FormatException('XHTTP requires a path.');
    }

    if (node.downloadSettings != null) {
      if (!node.isXhttp) {
        throw const FormatException(
          'Split download settings require XHTTP on the upload side.',
        );
      }
      if (node.mode.toLowerCase() == 'stream-one') {
        throw const FormatException(
          'stream-one cannot be used together with XHTTP downloadSettings.',
        );
      }
      _validateDownloadSettings(node.downloadSettings!);
    }
  }

  void _validateDownloadSettings(XhttpDownloadSettings download) {
    if (download.address.trim().isEmpty) {
      throw const FormatException('Split download requires an address.');
    }
    if (download.port <= 0 || download.port > 65535) {
      throw const FormatException('Split download requires a valid port.');
    }
    if (!download.isXhttp) {
      throw const FormatException(
        'Split download currently expects network=xhttp.',
      );
    }
    if (download.path.trim().isEmpty) {
      throw const FormatException('Split download XHTTP requires a path.');
    }

    _validateSecurity(
      label: 'Download',
      security: download.security,
      serverName: download.serverName,
      fingerprint: download.fingerprint,
      publicKey: download.publicKey,
    );
  }

  void _validateSecurity({
    required String label,
    required String security,
    required String serverName,
    required String fingerprint,
    required String publicKey,
  }) {
    final String normalizedSecurity = security.toLowerCase();
    if (normalizedSecurity == 'reality') {
      if (publicKey.isEmpty) {
        throw FormatException('$label REALITY requires a public key.');
      }
      if (serverName.isEmpty) {
        throw FormatException('$label REALITY requires serverName or sni.');
      }
      if (fingerprint.isEmpty) {
        throw FormatException('$label REALITY requires fingerprint.');
      }
      return;
    }

    if (normalizedSecurity == 'tls') {
      if (serverName.isEmpty) {
        throw FormatException('$label TLS requires serverName or sni.');
      }
      if (fingerprint.isEmpty) {
        throw FormatException('$label TLS requires fingerprint.');
      }
    }
  }

  Map<String, dynamic> _buildDns(RoutingPreset preset) {
    switch (preset) {
      case RoutingPreset.cnDirect:
        return <String, dynamic>{
          'hosts': <String, dynamic>{
            'geosite:category-ads-all': '127.0.0.1',
          },
          'servers': <dynamic>[
            <String, dynamic>{
              'address': 'https://1.1.1.1/dns-query',
              'domains': <String>['geosite:geolocation-!cn'],
              'expectIPs': <String>['geoip:!cn'],
            },
            <String, dynamic>{
              'address': '223.5.5.5',
              'port': 53,
              'domains': <String>['geosite:cn', 'geosite:private'],
              'expectIPs': <String>['geoip:cn'],
              'skipFallback': true,
            },
            <String, dynamic>{
              'address': 'localhost',
              'skipFallback': true,
            },
          ],
        };
      case RoutingPreset.globalProxy:
        return <String, dynamic>{
          'hosts': <String, dynamic>{
            'geosite:category-ads-all': '127.0.0.1',
          },
          'servers': <dynamic>[
            'https://1.1.1.1/dns-query',
            '8.8.8.8',
            <String, dynamic>{
              'address': 'localhost',
              'skipFallback': true,
            },
          ],
        };
      case RoutingPreset.gfwLike:
        return <String, dynamic>{
          'hosts': <String, dynamic>{
            'geosite:category-ads-all': '127.0.0.1',
          },
          'servers': <dynamic>[
            'https://1.1.1.1/dns-query',
            '223.5.5.5',
            <String, dynamic>{
              'address': 'localhost',
              'skipFallback': true,
            },
          ],
        };
    }
  }

  List<Map<String, dynamic>> _buildInbounds(Profile profile) {
    final List<Map<String, dynamic>> localProxyInbounds =
        <Map<String, dynamic>>[
      <String, dynamic>{
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'port': profile.socksPort,
        'protocol': 'socks',
        'settings': <String, dynamic>{
          'udp': true,
          'auth': 'noauth',
        },
      },
      <String, dynamic>{
        'tag': 'http-in',
        'listen': '127.0.0.1',
        'port': profile.httpPort,
        'protocol': 'http',
        'settings': <String, dynamic>{},
      },
    ];

    if (profile.runtimeMode == RuntimeMode.vpn) {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'tun-in',
          'port': 0,
          'protocol': 'tun',
          'settings': <String, dynamic>{
            'name': 'xray0',
            'MTU': profile.tunMtu,
          },
        },
        ...localProxyInbounds,
      ];
    }

    return localProxyInbounds;
  }

  List<Map<String, dynamic>> _buildOutbounds(VlessNode node) {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'tag': 'proxy',
        'protocol': 'vless',
        'settings': <String, dynamic>{
          'vnext': <Map<String, dynamic>>[
            <String, dynamic>{
              'address': node.address,
              'port': node.port,
              'users': <Map<String, dynamic>>[
                _removeEmpty(<String, dynamic>{
                  'id': node.id,
                  'encryption': node.encryption,
                  'flow': node.flow,
                }),
              ],
            },
          ],
        },
        'streamSettings': _buildStreamSettings(node),
      },
      <String, dynamic>{
        'tag': 'direct',
        'protocol': 'freedom',
        'settings': <String, dynamic>{},
      },
      <String, dynamic>{
        'tag': 'block',
        'protocol': 'blackhole',
        'settings': <String, dynamic>{},
      },
    ];
  }

  Map<String, dynamic> _buildStreamSettings(VlessNode node) {
    return _removeEmpty(<String, dynamic>{
      'network': node.network,
      'security': node.security,
      'tlsSettings': node.isTls
          ? _removeEmpty(<String, dynamic>{
              'serverName': node.serverName,
              'fingerprint': node.fingerprint,
              'alpn': node.alpn,
            })
          : null,
      'realitySettings': node.isReality
          ? _removeEmpty(<String, dynamic>{
              'serverName': node.serverName,
              'fingerprint': node.fingerprint,
              'publicKey': node.publicKey,
              'shortId': node.shortId,
              'spiderX': node.spiderX,
            })
          : null,
      'xhttpSettings': node.isXhttp
          ? _removeEmpty(<String, dynamic>{
              'host': node.host,
              'path': node.path,
              'mode': node.mode,
              'downloadSettings': node.downloadSettings == null
                  ? null
                  : _buildDownloadSettings(node.downloadSettings!),
            })
          : null,
    });
  }

  Map<String, dynamic> _buildDownloadSettings(
    XhttpDownloadSettings download,
  ) {
    return _removeEmpty(<String, dynamic>{
      'address': download.address,
      'port': download.port,
      'network': download.network,
      'security': download.security,
      'tlsSettings': download.isTls
          ? _removeEmpty(<String, dynamic>{
              'serverName': download.serverName,
              'fingerprint': download.fingerprint,
              'alpn': download.alpn,
            })
          : null,
      'realitySettings': download.isReality
          ? _removeEmpty(<String, dynamic>{
              'serverName': download.serverName,
              'fingerprint': download.fingerprint,
              'publicKey': download.publicKey,
              'shortId': download.shortId,
              'spiderX': download.spiderX,
            })
          : null,
      'xhttpSettings': download.isXhttp
          ? _removeEmpty(<String, dynamic>{
              'host': download.host,
              'path': download.path,
              'mode': download.mode,
            })
          : null,
    });
  }

  List<Map<String, dynamic>> _buildRoutingRules(RoutingPreset preset) {
    switch (preset) {
      case RoutingPreset.cnDirect:
        return <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'block',
            'domain': <String>['geosite:category-ads-all'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'direct',
            'domain': <String>[
              'geosite:private',
              'geosite:apple-cn',
              'geosite:google-cn',
              'geosite:tld-cn',
            ],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'proxy',
            'domain': <String>['geosite:geolocation-!cn'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'direct',
            'domain': <String>['geosite:cn'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'direct',
            'ip': <String>['geoip:cn', 'geoip:private'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'proxy',
            'network': 'tcp,udp',
          },
        ];
      case RoutingPreset.globalProxy:
        return <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'block',
            'domain': <String>['geosite:category-ads-all'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'direct',
            'domain': <String>['geosite:private'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'direct',
            'ip': <String>['geoip:private'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'proxy',
            'network': 'tcp,udp',
          },
        ];
      case RoutingPreset.gfwLike:
        return <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'block',
            'domain': <String>['geosite:category-ads-all'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'proxy',
            'domain': <String>['geosite:gfw'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'proxy',
            'ip': <String>['geoip:telegram'],
          },
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'direct',
            'network': 'tcp,udp',
          },
        ];
    }
  }

  Map<String, dynamic> _removeEmpty(Map<String, dynamic> source) {
    source.removeWhere((String key, dynamic value) {
      if (value == null) {
        return true;
      }
      if (value is String) {
        return value.trim().isEmpty;
      }
      if (value is List) {
        return value.isEmpty;
      }
      if (value is Map) {
        return value.isEmpty;
      }
      return false;
    });
    return source;
  }
}
