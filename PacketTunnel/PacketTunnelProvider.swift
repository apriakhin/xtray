import Darwin
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let xrayRuntime = LibXrayRuntime()

    private var configuration: ProviderVLESSConfiguration?
    private var configURL: URL?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        appendDiagnosticLog("startTunnel called")

        do {
            let configuration = try ProviderVLESSConfiguration(protocolConfiguration: protocolConfiguration)
            self.configuration = configuration

            let serverIPv4Addresses = resolveIPv4Addresses(for: configuration.host)
            appendDiagnosticLog("Resolved server addresses: \(serverIPv4Addresses)")
            installNetworkSettings(for: configuration, serverIPv4Addresses: serverIPv4Addresses) { [weak self] error in
                guard let self else { return }

                if let error {
                    self.failStartup(error, completionHandler: completionHandler)
                    return
                }

                self.appendDiagnosticLog("Network settings installed")

                do {
                    let tunnelInterface = try self.findTunnelInterface()
                    let configDirectoryURL = try self.makeXrayConfigurationDirectory()
                    let configJSON = try XrayConfigurationBuilder(
                        configuration: configuration,
                        tunInterfaceName: tunnelInterface.name,
                        logDirectory: configDirectoryURL
                    ).makeJSON()
                    let configURL = try self.writeXrayConfiguration(configJSON, in: configDirectoryURL)
                    self.configURL = configURL
                    self.appendDiagnosticLog("Starting Xray on interface \(tunnelInterface.name), fd \(tunnelInterface.fileDescriptor), config \(configURL.path)")

                    try self.xrayRuntime.test(configPath: configURL.path)
                    try self.xrayRuntime.run(configPath: configURL.path, tunFileDescriptor: tunnelInterface.fileDescriptor)
                    self.appendDiagnosticLog("Xray started")
                    completionHandler(nil)
                } catch {
                    self.failStartup(error, completionHandler: completionHandler)
                }
            }
        } catch {
            failStartup(error, completionHandler: completionHandler)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        xrayRuntime.stop()
        removeGeneratedConfiguration()
        configuration = nil
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {}

    private func installNetworkSettings(
        for configuration: ProviderVLESSConfiguration,
        serverIPv4Addresses: [String],
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.host)
        settings.mtu = 1500

        let ipv4Settings = NEIPv4Settings(addresses: ["10.255.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        ipv4Settings.excludedRoutes = makeExcludedIPv4Routes(serverIPv4Addresses: serverIPv4Addresses)
        settings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }

    private func makeExcludedIPv4Routes(serverIPv4Addresses: [String]) -> [NEIPv4Route] {
        serverIPv4Addresses.map { address in
            NEIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255")
        }
    }

    private func resolveIPv4Addresses(for host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?

        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            return []
        }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let pointer = current {
            if let socketAddress = pointer.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 }) {
                var address = socketAddress.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil {
                    addresses.append(String(cString: buffer))
                }
            }
            current = pointer.pointee.ai_next
        }

        return Array(Set(addresses)).sorted()
    }

    private func findTunnelInterface() throws -> TunnelInterface {
        for fileDescriptor in Int32(0)..<1024 {
            var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(nameBuffer.count)
            let result = nameBuffer.withUnsafeMutableBufferPointer { buffer in
                getsockopt(fileDescriptor, 2, 2, buffer.baseAddress, &length)
            }

            guard result == 0 else { continue }

            let interfaceName = String(cString: nameBuffer)
            if interfaceName.hasPrefix("utun") {
                return TunnelInterface(fileDescriptor: fileDescriptor, name: interfaceName)
            }
        }

        throw PacketTunnelError.tunnelFileDescriptorNotFound
    }

    private func failStartup(_ error: Error, completionHandler: @escaping (Error?) -> Void) {
        appendDiagnosticLog("Startup failed: \(error.localizedDescription)")
        xrayRuntime.stop()
        removeGeneratedConfiguration()
        configuration = nil
        completionHandler(error)
    }

    private func makeXrayConfigurationDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XTray-Xray", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeXrayConfiguration(_ json: String, in directoryURL: URL) throws -> URL {
        let configURL = directoryURL.appendingPathComponent("config.json")
        try json.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private func removeGeneratedConfiguration() {
        guard let configURL else { return }
        try? FileManager.default.removeItem(at: configURL)
        self.configURL = nil
    }

    private func appendDiagnosticLog(_ message: String) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XTray-Xray", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let logURL = directoryURL.appendingPathComponent("provider.log")
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            handle.closeFile()
        } else {
            try? data.write(to: logURL)
        }
    }
}

private struct TunnelInterface {
    let fileDescriptor: Int32
    let name: String
}

struct ProviderVLESSConfiguration {
    let id: UUID
    let host: String
    let port: Int
    let encryption: String
    let security: String
    let network: String
    let path: String?
    let hostHeader: String?
    let rawURI: String
    let parameters: [String: String]
    let splitRuDomainsEnabled: Bool

    var serverName: String? {
        parameters["sni"] ?? hostHeader
    }

    init(protocolConfiguration: NEVPNProtocol) throws {
        guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = tunnelProtocol.providerConfiguration else {
            throw PacketTunnelError.missingProviderConfiguration
        }

        guard let rawURI = providerConfiguration["vlessURI"] as? String else {
            throw PacketTunnelError.invalidProviderConfiguration("Missing VLESS share link.")
        }

        let parameters = Self.makeParameters(from: rawURI)

        guard let idString = providerConfiguration["id"] as? String,
              let id = UUID(uuidString: idString) else {
            throw PacketTunnelError.invalidProviderConfiguration("Missing or invalid VLESS UUID.")
        }

        guard let host = providerConfiguration["host"] as? String, !host.isEmpty else {
            throw PacketTunnelError.invalidProviderConfiguration("Missing VLESS host.")
        }

        guard let port = providerConfiguration["port"] as? Int, (1...65535).contains(port) else {
            throw PacketTunnelError.invalidProviderConfiguration("Missing or invalid VLESS port.")
        }

        self.id = id
        self.host = host
        self.port = port
        self.encryption = providerConfiguration["encryption"] as? String ?? "none"
        self.security = providerConfiguration["security"] as? String ?? "none"
        self.network = providerConfiguration["network"] as? String ?? "tcp"
        self.path = providerConfiguration["path"] as? String
        self.hostHeader = providerConfiguration["hostHeader"] as? String
        self.rawURI = rawURI
        self.parameters = parameters
        self.splitRuDomainsEnabled = providerConfiguration["splitRuDomainsEnabled"] as? Bool ?? true
    }

    private static func makeParameters(from rawURI: String) -> [String: String] {
        guard let components = URLComponents(string: rawURI) else { return [:] }

        var parameters: [String: String] = [:]
        for queryItem in components.queryItems ?? [] {
            parameters[queryItem.name] = queryItem.value ?? ""
            parameters[queryItem.name.lowercased()] = queryItem.value ?? ""
        }

        return parameters
    }
}

enum PacketTunnelError: LocalizedError {
    case missingProviderConfiguration
    case invalidProviderConfiguration(String)
    case tunnelFileDescriptorNotFound

    var errorDescription: String? {
        switch self {
        case .missingProviderConfiguration:
            "Packet tunnel did not receive provider configuration."
        case .invalidProviderConfiguration(let reason):
            reason
        case .tunnelFileDescriptorNotFound:
            "Unable to find the utun file descriptor for PacketTunnelFlow."
        }
    }
}
