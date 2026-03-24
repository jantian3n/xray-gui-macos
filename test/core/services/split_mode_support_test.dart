import 'package:flutter_test/flutter_test.dart';
import 'package:xray_gui/src/core/models/profile.dart';
import 'package:xray_gui/src/core/models/vless_node.dart';
import 'package:xray_gui/src/core/models/xhttp_download_settings.dart';
import 'package:xray_gui/src/core/services/node_importer.dart';
import 'package:xray_gui/src/core/services/vless_uri_parser.dart';
import 'package:xray_gui/src/core/services/xray_config_compiler.dart';

void main() {
  group('XrayConfigCompiler', () {
    test('compiles split reality downloadSettings for xhttp', () {
      final VlessNode node = VlessNode(
        name: 'split-reality',
        address: '2400:8d60:3::4034:271c',
        port: 443,
        id: 'a7050a6f-96df-4e6a-8a5c-fa98664275dc',
        network: 'xhttp',
        security: 'reality',
        serverName: 'download-installer.cdn.mozilla.net',
        fingerprint: 'chrome',
        publicKey: 'upload-public-key',
        shortId: '0c8cf1635139e0b3',
        spiderX: '/',
        path: '/c1a13b04daf2',
        mode: 'auto',
        downloadSettings: const XhttpDownloadSettings(
          address: '203.0.113.10',
          port: 443,
          network: 'xhttp',
          security: 'reality',
          serverName: 'download-installer.cdn.mozilla.net',
          fingerprint: 'chrome',
          publicKey: 'download-public-key',
          shortId: '0c8cf1635139e0b3',
          spiderX: '/',
          path: '/c1a13b04daf2',
          mode: 'auto',
        ),
      );

      final Map<String, dynamic> config =
          XrayConfigCompiler().compile(Profile.fromNode(node));
      final Map<String, dynamic> outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final Map<String, dynamic> streamSettings =
          outbound['streamSettings'] as Map<String, dynamic>;
      final Map<String, dynamic> xhttpSettings =
          streamSettings['xhttpSettings'] as Map<String, dynamic>;
      final Map<String, dynamic> downloadSettings =
          xhttpSettings['downloadSettings'] as Map<String, dynamic>;
      final Map<String, dynamic> downloadReality =
          downloadSettings['realitySettings'] as Map<String, dynamic>;

      expect(streamSettings['security'], 'reality');
      expect(streamSettings['realitySettings'], isNotNull);
      expect(downloadSettings['address'], '203.0.113.10');
      expect(downloadSettings['network'], 'xhttp');
      expect(downloadReality['publicKey'], 'download-public-key');
      expect(
        (downloadSettings['xhttpSettings'] as Map<String, dynamic>)['path'],
        '/c1a13b04daf2',
      );
    });

    test('compiles CDN TLS split mode with upload and download tlsSettings',
        () {
      final VlessNode node = VlessNode(
        name: 'cdn-tls-split',
        address: 'cdn.example.com',
        port: 443,
        id: '11111111-2222-3333-4444-555555555555',
        network: 'xhttp',
        security: 'tls',
        serverName: 'cdn.example.com',
        fingerprint: 'chrome',
        path: '/edge-path',
        mode: 'auto',
        alpn: const <String>['h2'],
        downloadSettings: const XhttpDownloadSettings(
          address: 'origin.example.com',
          port: 443,
          network: 'xhttp',
          security: 'tls',
          serverName: 'origin.example.com',
          fingerprint: 'chrome',
          path: '/edge-path',
          mode: 'auto',
          alpn: <String>['h2'],
        ),
      );

      final Map<String, dynamic> config =
          XrayConfigCompiler().compile(Profile.fromNode(node));
      final Map<String, dynamic> outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final Map<String, dynamic> streamSettings =
          outbound['streamSettings'] as Map<String, dynamic>;
      final Map<String, dynamic> tlsSettings =
          streamSettings['tlsSettings'] as Map<String, dynamic>;
      final Map<String, dynamic> downloadSettings =
          (streamSettings['xhttpSettings']
                  as Map<String, dynamic>)['downloadSettings']
              as Map<String, dynamic>;
      final Map<String, dynamic> downloadTls =
          downloadSettings['tlsSettings'] as Map<String, dynamic>;

      expect(streamSettings['security'], 'tls');
      expect(tlsSettings['serverName'], 'cdn.example.com');
      expect(tlsSettings['alpn'], <String>['h2']);
      expect(downloadSettings['address'], 'origin.example.com');
      expect(downloadTls['serverName'], 'origin.example.com');
      expect(downloadTls['alpn'], <String>['h2']);
    });
  });

  group('NodeImporter', () {
    test('imports script-style client_outbound json with split reality', () {
      const String outboundJson = '''
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "2400:8d60:3::4034:271c",
        "port": 443,
        "users": [
          {
            "id": "a7050a6f-96df-4e6a-8a5c-fa98664275dc",
            "encryption": "none"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "download-installer.cdn.mozilla.net",
      "fingerprint": "chrome",
      "publicKey": "upload-public-key",
      "shortId": "0c8cf1635139e0b3",
      "spiderX": "/"
    },
    "xhttpSettings": {
      "path": "/c1a13b04daf2",
      "mode": "auto",
      "downloadSettings": {
        "address": "203.0.113.10",
        "port": 443,
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "serverName": "download-installer.cdn.mozilla.net",
          "fingerprint": "chrome",
          "publicKey": "download-public-key",
          "shortId": "0c8cf1635139e0b3",
          "spiderX": "/"
        },
        "xhttpSettings": {
          "path": "/c1a13b04daf2",
          "mode": "auto"
        }
      }
    }
  }
}
''';

      final VlessNode node = NodeImporter().parseNode(outboundJson);

      expect(node.address, '2400:8d60:3::4034:271c');
      expect(node.security, 'reality');
      expect(node.path, '/c1a13b04daf2');
      expect(node.downloadSettings, isNotNull);
      expect(node.downloadSettings!.address, '203.0.113.10');
      expect(node.downloadSettings!.publicKey, 'download-public-key');
    });

    test('applies split patch onto a base vless node', () {
      const String rawLink =
          'vless://a7050a6f-96df-4e6a-8a5c-fa98664275dc@[2400:8d60:3::4034:271c]:443?encryption=none&type=xhttp&path=%2Fc1a13b04daf2&mode=auto&security=reality&sni=download-installer.cdn.mozilla.net&fp=chrome&pbk=j6wrDq0b8yyV8KYRZVXWZ8e3KULLewrc7nqSpXWoi1I&sid=0c8cf1635139e0b3&spx=%2F#VLESS-XHTTP-IPv6UP-IPv4DOWN';
      const String patchJson = '''
{
  "downloadSettings": {
    "address": "203.0.113.10",
    "port": 443,
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "download-installer.cdn.mozilla.net",
      "fingerprint": "chrome",
      "publicKey": "download-public-key",
      "shortId": "0c8cf1635139e0b3",
      "spiderX": "/"
    },
    "xhttpSettings": {
      "path": "/c1a13b04daf2",
      "mode": "auto"
    }
  }
}
''';

      final VlessNode baseNode = VlessUriParser().parse(rawLink);
      final VlessNode merged = NodeImporter().applyPatch(baseNode, patchJson);

      expect(merged.downloadSettings, isNotNull);
      expect(merged.downloadSettings!.address, '203.0.113.10');
      expect(merged.downloadSettings!.security, 'reality');
      expect(merged.downloadSettings!.path, '/c1a13b04daf2');
    });
  });
}
