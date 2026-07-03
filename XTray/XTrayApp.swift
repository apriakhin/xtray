import SwiftUI

@main
struct XTrayApp: App {
    @State private var controller = TunnelController()

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            Image(systemName: controller.isConnectedOrConnecting ? "leaf.fill" : "leaf")
        }
        .menuBarExtraStyle(.window)
    }
}
