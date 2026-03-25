import XCTest
@testable import XrayNativeCore

final class XrayNativeCoreTests: XCTestCase {
    func testCompilerIncludesSplitRealityDownloadSettingsForXHTTP() throws {
        let node = VLESSNode(
            name: "split-reality",
            address: "2400:8d60:3::4034:271c",
            port: 443,
            id: "a7050a6f-96df-4e6a-8a5c-fa98664275dc",
            network: "xhttp",
            security: "reality",
            serverName: "download-installer.cdn.mozilla.net",
            fingerprint: "chrome",
            publicKey: "upload-public-key",
            shortID: "0c8cf1635139e0b3",
            spiderX: "/",
            path: "/c1a13b04daf2",
            mode: "auto",
            downloadSettings: XHTTPDownloadSettings(
                address: "203.0.113.10",
                port: 443,
                network: "xhttp",
                security: "reality",
                serverName: "download-installer.cdn.mozilla.net",
                fingerprint: "chrome",
                publicKey: "download-public-key",
                shortID: "0c8cf1635139e0b3",
                spiderX: "/",
                path: "/c1a13b04daf2",
                mode: "auto"
            )
        )

        let config = try XrayConfigCompiler().compile(Profile.fromNode(node))
        let outbound = try XCTUnwrap((config["outbounds"] as? [[String: Any]])?.first)
        let streamSettings = try XCTUnwrap(outbound["streamSettings"] as? [String: Any])
        let xhttpSettings = try XCTUnwrap(streamSettings["xhttpSettings"] as? [String: Any])
        let downloadSettings = try XCTUnwrap(xhttpSettings["downloadSettings"] as? [String: Any])
        let downloadReality = try XCTUnwrap(downloadSettings["realitySettings"] as? [String: Any])

        XCTAssertEqual(streamSettings["security"] as? String, "reality")
        XCTAssertNotNil(streamSettings["realitySettings"])
        XCTAssertEqual(downloadSettings["address"] as? String, "203.0.113.10")
        XCTAssertEqual(downloadSettings["network"] as? String, "xhttp")
        XCTAssertEqual(downloadReality["publicKey"] as? String, "download-public-key")
        XCTAssertEqual((downloadSettings["xhttpSettings"] as? [String: Any])?["path"] as? String, "/c1a13b04daf2")
    }

    func testCompilerIncludesTLSSplitModeForUploadAndDownload() throws {
        let node = VLESSNode(
            name: "cdn-tls-split",
            address: "cdn.example.com",
            port: 443,
            id: "11111111-2222-3333-4444-555555555555",
            network: "xhttp",
            security: "tls",
            serverName: "cdn.example.com",
            fingerprint: "chrome",
            path: "/edge-path",
            mode: "auto",
            alpn: ["h2"],
            downloadSettings: XHTTPDownloadSettings(
                address: "origin.example.com",
                port: 443,
                network: "xhttp",
                security: "tls",
                serverName: "origin.example.com",
                fingerprint: "chrome",
                path: "/edge-path",
                mode: "auto",
                alpn: ["h2"]
            )
        )

        let config = try XrayConfigCompiler().compile(Profile.fromNode(node))
        let outbound = try XCTUnwrap((config["outbounds"] as? [[String: Any]])?.first)
        let streamSettings = try XCTUnwrap(outbound["streamSettings"] as? [String: Any])
        let tlsSettings = try XCTUnwrap(streamSettings["tlsSettings"] as? [String: Any])
        let xhttpSettings = try XCTUnwrap(streamSettings["xhttpSettings"] as? [String: Any])
        let downloadSettings = try XCTUnwrap(xhttpSettings["downloadSettings"] as? [String: Any])
        let downloadTLS = try XCTUnwrap(downloadSettings["tlsSettings"] as? [String: Any])

        XCTAssertEqual(streamSettings["security"] as? String, "tls")
        XCTAssertEqual(tlsSettings["serverName"] as? String, "cdn.example.com")
        XCTAssertEqual(tlsSettings["alpn"] as? [String], ["h2"])
        XCTAssertEqual(downloadSettings["address"] as? String, "origin.example.com")
        XCTAssertEqual(downloadTLS["serverName"] as? String, "origin.example.com")
        XCTAssertEqual(downloadTLS["alpn"] as? [String], ["h2"])
    }

    func testNodeImporterParsesScriptStyleOutboundWithSplitReality() throws {
        let outboundJSON = """
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
        """

        let node = try NodeImporter().parseNode(outboundJSON)
        XCTAssertEqual(node.address, "2400:8d60:3::4034:271c")
        XCTAssertEqual(node.security, "reality")
        XCTAssertEqual(node.path, "/c1a13b04daf2")
        XCTAssertEqual(node.downloadSettings?.address, "203.0.113.10")
        XCTAssertEqual(node.downloadSettings?.publicKey, "download-public-key")
    }

    func testNodeImporterAppliesSplitPatchToBaseNode() throws {
        let rawLink = "vless://a7050a6f-96df-4e6a-8a5c-fa98664275dc@[2400:8d60:3::4034:271c]:443?encryption=none&type=xhttp&path=%2Fc1a13b04daf2&mode=auto&security=reality&sni=download-installer.cdn.mozilla.net&fp=chrome&pbk=j6wrDq0b8yyV8KYRZVXWZ8e3KULLewrc7nqSpXWoi1I&sid=0c8cf1635139e0b3&spx=%2F#VLESS-XHTTP-IPv6UP-IPv4DOWN"
        let patchJSON = """
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
        """

        let baseNode = try VLESSURIParser().parse(rawLink)
        let merged = try NodeImporter().applyPatch(baseNode: baseNode, raw: patchJSON)

        XCTAssertEqual(merged.downloadSettings?.address, "203.0.113.10")
        XCTAssertEqual(merged.downloadSettings?.security, "reality")
        XCTAssertEqual(merged.downloadSettings?.path, "/c1a13b04daf2")
    }
}
