import Foundation

struct VLESSConfiguration: Equatable {
    let id: UUID
    let host: String
    let port: Int
    let name: String
    let encryption: String
    let security: String
    let network: String
    let path: String?
    let hostHeader: String?
    let rawURI: String

    var displayName: String {
        name.isEmpty ? "\(host):\(port)" : name
    }

    var providerConfiguration: [String: Any] {
        var configuration: [String: Any] = [
            "vlessURI": rawURI,
            "id": id.uuidString.lowercased(),
            "host": host,
            "port": port,
            "name": displayName,
            "encryption": encryption,
            "security": security,
            "network": network
        ]

        if let path, !path.isEmpty {
            configuration["path"] = path
        }

        if let hostHeader, !hostHeader.isEmpty {
            configuration["hostHeader"] = hostHeader
        }

        return configuration
    }

    init(uri: String) throws {
        let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURI.isEmpty else {
            throw VLESSConfigurationError.emptyConfiguration
        }

        guard var components = URLComponents(string: trimmedURI), components.scheme?.lowercased() == "vless" else {
            throw VLESSConfigurationError.invalidScheme
        }

        guard let user = components.user, let id = UUID(uuidString: user) else {
            throw VLESSConfigurationError.invalidUserID
        }

        guard let host = components.host, !host.isEmpty else {
            throw VLESSConfigurationError.missingHost
        }

        guard let port = components.port else {
            throw VLESSConfigurationError.missingPort
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name.lowercased()] = item.value ?? ""
        }

        let fragment = components.percentEncodedFragment.flatMap { fragment in
            fragment.removingPercentEncoding
        }

        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil

        self.id = id
        self.host = host
        self.port = port
        self.name = fragment ?? ""
        self.encryption = query["encryption"] ?? "none"
        self.security = query["security"] ?? "none"
        self.network = query["type"] ?? "tcp"
        self.path = query["path"]
        self.hostHeader = query["host"] ?? query["sni"]
        self.rawURI = trimmedURI
    }
}

enum VLESSConfigurationError: LocalizedError {
    case emptyConfiguration
    case invalidScheme
    case invalidUserID
    case missingHost
    case missingPort

    var errorDescription: String? {
        switch self {
        case .emptyConfiguration:
            "Paste a VLESS URI first."
        case .invalidScheme:
            "Configuration must start with vless://."
        case .invalidUserID:
            "VLESS URI must contain a valid UUID before @."
        case .missingHost:
            "VLESS URI is missing a server host."
        case .missingPort:
            "VLESS URI is missing a server port."
        }
    }
}
