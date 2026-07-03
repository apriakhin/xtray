import Foundation

struct XrayConfigurationBuilder {
    let configuration: ProviderVLESSConfiguration
    let tunInterfaceName: String
    let logDirectory: URL

    func makeJSON() throws -> String {
        var object: [String: Any] = [
            "log": [
                "access": logDirectory.appendingPathComponent("access.log").path,
                "error": logDirectory.appendingPathComponent("error.log").path,
                "loglevel": "debug"
            ],
            "inbounds": [
                tunInbound
            ],
            "outbounds": [
                vlessOutbound,
                [
                    "tag": "direct",
                    "protocol": "freedom"
                ],
                [
                    "tag": "block",
                    "protocol": "blackhole"
                ]
            ]
        ]

        if configuration.splitRuDomainsEnabled {
            object["routing"] = ruSplitRouting
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw XrayConfigurationBuilderError.encodingFailed
        }

        return json
    }

    private var ruSplitRouting: [String: Any] {
        [
            "domainStrategy": "AsIs",
            "rules": [
                [
                    "type": "field",
                    "domain": [
                        "regexp:.*\\.ru$"
                    ],
                    "outboundTag": "direct"
                ]
            ]
        ]
    }

    private var tunInbound: [String: Any] {
        [
            "tag": "tun-in",
            "protocol": "tun",
            "settings": [
                "name": tunInterfaceName,
                "mtu": 1500,
                "gateway": ["10.255.0.2/24"],
                "dns": ["1.1.1.1", "8.8.8.8"],
                "userLevel": 0
            ],
            "sniffing": sniffing
        ]
    }

    private var sniffing: [String: Any] {
        [
            "enabled": true,
            "destOverride": ["http", "tls", "quic"]
        ]
    }

    private var vlessOutbound: [String: Any] {
        var user: [String: Any] = [
            "id": configuration.id.uuidString.lowercased(),
            "encryption": configuration.encryption
        ]

        if let flow = configuration.parameters["flow"], !flow.isEmpty {
            user["flow"] = flow
        }

        var outbound: [String: Any] = [
            "tag": "proxy",
            "protocol": "vless",
            "settings": [
                "vnext": [
                    [
                        "address": configuration.host,
                        "port": configuration.port,
                        "users": [user]
                    ]
                ]
            ]
        ]

        let streamSettings = makeStreamSettings()
        if !streamSettings.isEmpty {
            outbound["streamSettings"] = streamSettings
        }

        return outbound
    }

    private func makeStreamSettings() -> [String: Any] {
        var settings: [String: Any] = [
            "network": configuration.network,
            "security": configuration.security
        ]

        switch configuration.security {
        case "tls":
            settings["tlsSettings"] = makeTLSSettings()
        case "reality":
            settings["realitySettings"] = makeRealitySettings()
        default:
            break
        }

        switch configuration.network {
        case "ws":
            settings["wsSettings"] = makeWebSocketSettings()
        case "grpc":
            settings["grpcSettings"] = makeGRPCSettings()
        case "http", "h2":
            settings["httpSettings"] = makeHTTPSettings()
        default:
            break
        }

        return settings
    }

    private func makeTLSSettings() -> [String: Any] {
        var settings: [String: Any] = [:]

        if let serverName = configuration.serverName {
            settings["serverName"] = serverName
        }

        if let fingerprint = configuration.parameters["fp"], !fingerprint.isEmpty {
            settings["fingerprint"] = fingerprint
        }

        if configuration.parameters["allowInsecure"] == "1" || configuration.parameters["allowInsecure"] == "true" {
            settings["allowInsecure"] = true
        }

        return settings
    }

    private func makeRealitySettings() -> [String: Any] {
        var settings = makeTLSSettings()

        if let publicKey = configuration.parameters["pbk"], !publicKey.isEmpty {
            settings["publicKey"] = publicKey
        }

        if let shortID = configuration.parameters["sid"], !shortID.isEmpty {
            settings["shortId"] = shortID
        }

        if let spiderX = configuration.parameters["spx"], !spiderX.isEmpty {
            settings["spiderX"] = spiderX
        }

        return settings
    }

    private func makeWebSocketSettings() -> [String: Any] {
        var settings: [String: Any] = [:]

        if let path = configuration.path, !path.isEmpty {
            settings["path"] = path
        }

        if let hostHeader = configuration.hostHeader, !hostHeader.isEmpty {
            settings["headers"] = ["Host": hostHeader]
        }

        return settings
    }

    private func makeGRPCSettings() -> [String: Any] {
        guard let serviceName = configuration.parameters["serviceName"], !serviceName.isEmpty else {
            return [:]
        }

        return ["serviceName": serviceName]
    }

    private func makeHTTPSettings() -> [String: Any] {
        var settings: [String: Any] = [:]

        if let path = configuration.path, !path.isEmpty {
            settings["path"] = [path]
        }

        if let hostHeader = configuration.hostHeader, !hostHeader.isEmpty {
            settings["host"] = [hostHeader]
        }

        return settings
    }
}

enum XrayConfigurationBuilderError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "Unable to encode Xray configuration."
        }
    }
}
