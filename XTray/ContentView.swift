import AppKit
import NetworkExtension
import SwiftUI

struct ContentView: View {
    @Bindable var controller: TunnelController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                connectionSummary(now: context.date)
                errorMessage
                statusMessage
                actions
            }
            .padding(16)
        }
        .task {
            await controller.loadManager()
        }
    }

    private func connectionSummary(now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.title2)
                .foregroundStyle(serverIconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(controller.statusText)
                        .font(.headline)

                    if let duration = controller.connectionDurationText(now: now) {
                        Text(duration)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text(endpointText)
                        .lineLimit(1)

                    if controller.parsedConfiguration != nil {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(transportText)
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(securityText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if controller.isBusy || controller.status == .connecting || controller.status == .disconnecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var connectionButton: some View {
        Button(
            controller.isConnectedOrConnecting ? "Disconnect" : "Connect",
            systemImage: controller.isConnectedOrConnecting ? "stop.fill" : "play.fill"
        ) {
            Task {
                await controller.connectOrDisconnect()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!controller.canConnect && !controller.isConnectedOrConnecting)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            connectionButton

            Spacer(minLength: 8)

            Menu {
                Button("Import from Clipboard", systemImage: "doc.on.clipboard") {
                    pasteConfigurationFromClipboard()
                }

                Button("Reset Config", systemImage: "trash") {
                    controller.resetConfiguration()
                }
                .disabled(controller.parsedConfiguration == nil)

                Toggle(isOn: $controller.splitRuDomainsEnabled) {
                    Label("GeoSite Routing", systemImage: "globe")
                }

                Divider()

                Button("Quit", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel("Settings")
            }
            .menuStyle(.button)
            .disabled(controller.isConnectedOrConnecting)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let successMessage = controller.successMessage, !successMessage.isEmpty {
            Label(successMessage, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let lastError = controller.lastError, !lastError.isEmpty {
            Label(lastError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var endpointText: String {
        guard let configuration = controller.parsedConfiguration else {
            return "No VLESS config"
        }

        return "\(configuration.host):\(configuration.port)"
    }

    private var transportText: String {
        guard let configuration = controller.parsedConfiguration else { return "-" }
        return configuration.network.uppercased()
    }

    private var securityText: String {
        guard let configuration = controller.parsedConfiguration else { return "-" }
        return configuration.security.uppercased()
    }

    private var serverIconColor: Color {
        controller.isConnected ? .green : .secondary
    }

    private func pasteConfigurationFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            controller.successMessage = nil
            controller.lastError = "Clipboard does not contain a VLESS config."
            return
        }

        controller.updateConfigurationText(text)
    }
}

#Preview {
    ContentView(controller: TunnelController())
}
