import Foundation
import NetworkExtension
import Observation
import SystemExtensions

@MainActor
@Observable
final class TunnelController {
    var vlessURI: String = ""
    var status: NEVPNStatus = .invalid
    var isBusy = false
    var lastError: String?
    var successMessage: String? {
        didSet { scheduleMessageClear() }
    }
    var parsedConfiguration: VLESSConfiguration?
    var connectedAt: Date?
    var splitRuDomainsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(splitRuDomainsEnabled, forKey: Self.splitRuDomainsEnabledKey)
        }
    }

    private static let vlessURIKey = "vlessURI"
    private static let splitRuDomainsEnabledKey = "splitRuDomainsEnabled"

    private let managerDescription = "XTray VLESS"
    private let providerBundleIdentifier: String
    private let systemExtensionInstaller = SystemExtensionInstaller()
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    @ObservationIgnored private var messageClearTask: Task<Void, Never>?

    init() {
        let baseIdentifier = Bundle.main.bundleIdentifier ?? "com.apriakhin.XTray"
        providerBundleIdentifier = "\(baseIdentifier).PacketTunnel"
        vlessURI = UserDefaults.standard.string(forKey: Self.vlessURIKey) ?? ""
        splitRuDomainsEnabled = UserDefaults.standard.object(forKey: Self.splitRuDomainsEnabledKey) as? Bool ?? true

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncStatus()
            }
        }

        parseCurrentConfiguration()

        Task {
            await loadManager()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let statusObserver {
                NotificationCenter.default.removeObserver(statusObserver)
            }
            messageClearTask?.cancel()
        }
    }

    var canConnect: Bool {
        !isBusy && parsedConfiguration != nil && !providerBundleIdentifier.isEmpty
    }

    var isConnected: Bool {
        status == .connected || status == .reasserting
    }

    var isConnectedOrConnecting: Bool {
        isBusy || isConnected || status == .connecting
    }

    var statusText: String {
        switch status {
        case .invalid:
            "Not configured"
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .reasserting:
            "Reconnecting"
        case .disconnecting:
            "Disconnecting"
        @unknown default:
            "Unknown"
        }
    }

    func connectionDurationText(now: Date = Date()) -> String? {
        guard let connectedAt, isConnected else { return nil }

        let duration = max(0, Int(now.timeIntervalSince(connectedAt)))
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    func updateConfigurationText(_ text: String) {
        vlessURI = text
        UserDefaults.standard.set(text, forKey: Self.vlessURIKey)
        parseCurrentConfiguration()

        if let parsedConfiguration {
            successMessage = "Config updated: \(parsedConfiguration.displayName)"
        }
    }

    func resetConfiguration() {
        vlessURI = ""
        parsedConfiguration = nil
        UserDefaults.standard.removeObject(forKey: Self.vlessURIKey)
        lastError = nil
        successMessage = "Config reset."
    }

    func connectOrDisconnect() async {
        if isConnectedOrConnecting {
            disconnect()
        } else {
            await connect()
        }
    }

    func connect() async {
        guard let configuration = parsedConfiguration else {
            parseCurrentConfiguration()
            return
        }

        isBusy = true
        lastError = nil

        do {
            systemExtensionInstaller.onUserApprovalRequired = { [weak self] in
                self?.lastError = SystemExtensionInstallerError.activationRequiresUserApproval.localizedDescription
            }
            try await systemExtensionInstaller.activate(bundleIdentifier: providerBundleIdentifier)

            let manager = try await configuredManager(for: configuration)
            self.manager = manager
            syncStatus()

            try manager.connection.startVPNTunnel()
            syncStatus()

            let didConnect = await waitForStartResult(on: manager)
            if !didConnect {
                lastError = "Network Extension is not enabled. Open System Settings > General > Login Items & Extensions > Network Extensions, enable XTray, then press Connect again."
            }
        } catch {
            lastError = error.localizedDescription
        }

        isBusy = false
        syncStatus()
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
        syncStatus()
    }

    func loadManager() async {
        do {
            manager = try await existingManager()
            syncStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func parseCurrentConfiguration() {
        guard !vlessURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsedConfiguration = nil
            successMessage = nil
            lastError = nil
            return
        }

        do {
            parsedConfiguration = try VLESSConfiguration(uri: vlessURI)
            lastError = nil
        } catch {
            parsedConfiguration = nil
            successMessage = nil
            lastError = error.localizedDescription
        }
    }

    private func configuredManager(for configuration: VLESSConfiguration) async throws -> NETunnelProviderManager {
        let manager = try await existingManager() ?? NETunnelProviderManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        var providerConfiguration = configuration.providerConfiguration
        providerConfiguration["splitRuDomainsEnabled"] = splitRuDomainsEnabled

        tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
        tunnelProtocol.serverAddress = configuration.host
        tunnelProtocol.providerConfiguration = providerConfiguration
        tunnelProtocol.disconnectOnSleep = false

        manager.localizedDescription = managerDescription
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        if let reloadedManager = try await existingManager() {
            return reloadedManager
        }

        return manager
    }

    private func existingManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { $0.localizedDescription == managerDescription }
    }

    private func waitForStartResult(on manager: NETunnelProviderManager) async -> Bool {
        var sawStartupState = false

        for _ in 0..<40 {
            syncStatus()

            switch manager.connection.status {
            case .connected, .reasserting:
                return true
            case .connecting:
                sawStartupState = true
                try? await Task.sleep(for: .milliseconds(250))
            case .disconnecting:
                sawStartupState = true
                try? await Task.sleep(for: .milliseconds(250))
            case .disconnected, .invalid:
                if sawStartupState {
                    return false
                }
                try? await Task.sleep(for: .milliseconds(250))
            @unknown default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        syncStatus()
        return manager.connection.status == .connected
    }

    private func scheduleMessageClear() {
        messageClearTask?.cancel()

        guard successMessage?.isEmpty == false else {
            return
        }

        messageClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.successMessage = nil
            }
        }
    }

    private func syncStatus() {
        let nextStatus = manager?.connection.status ?? .invalid
        status = nextStatus

        if nextStatus == .connected || nextStatus == .reasserting {
            connectedAt = connectedAt ?? Date()
        } else if nextStatus == .disconnected || nextStatus == .invalid {
            connectedAt = nil
        }
    }
}

private final class SystemExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    var onUserApprovalRequired: (() -> Void)?

    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    func activate(bundleIdentifier: String) async throws {
        try await submitRequest(
            OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: bundleIdentifier,
                queue: .main
            )
        )
    }

    private func submitRequest(_ request: OSSystemExtensionRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard self.continuation == nil else {
                continuation.resume(throwing: SystemExtensionInstallerError.activationAlreadyInProgress)
                return
            }

            self.continuation = continuation

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.finish(with: .failure(SystemExtensionInstallerError.activationTimedOut))
            }
            self.timeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeoutWorkItem)

            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension extension: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onUserApprovalRequired?()
        finish(with: .failure(SystemExtensionInstallerError.activationRequiresUserApproval))
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            finish(with: .success(()))
        case .willCompleteAfterReboot:
            finish(with: .failure(SystemExtensionInstallerError.activationRequiresRestart))
        @unknown default:
            finish(with: .success(()))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Void, Error>) {
        guard let continuation else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        self.continuation = nil
        continuation.resume(with: result)
    }
}

private enum SystemExtensionInstallerError: LocalizedError {
    case activationAlreadyInProgress
    case activationTimedOut
    case activationRequiresRestart
    case activationRequiresUserApproval

    var errorDescription: String? {
        switch self {
        case .activationAlreadyInProgress:
            "System extension activation is already in progress."
        case .activationTimedOut:
            "System extension activation timed out. Move XTray to Applications and try again. If macOS asks for approval, keep XTray open until approval finishes."
        case .activationRequiresRestart:
            "System extension update requires a restart before the VPN can start."
        case .activationRequiresUserApproval:
            "Network Extension is not enabled. Open System Settings > General > Login Items & Extensions > Network Extensions, enable XTray, then press Connect again."
        }
    }
}
