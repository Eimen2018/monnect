import SwiftUI

enum WindowID {
    static let setup = "setup"
    static let settings = "settings"
}

struct MonnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(delegate.model)
        } label: {
            MenuLabel()
                .environmentObject(delegate.model)
        }

        Window("Set Up Monnect", id: WindowID.setup) {
            SetupView()
                .environmentObject(delegate.model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Monnect Settings", id: WindowID.settings) {
            SettingsView()
                .environmentObject(delegate.model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// monnect://pull and monnect://release — for Raycast, Shortcuts,
    /// hotkey tools: `open -g monnect://pull`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "monnect" {
            DiagLog.log("EVENT url \(url.absoluteString)")
            switch url.host {
            case "pull": model.pull()
            case "release": model.releaseHere()
            default: break
            }
        }
    }
}

extension OpenWindowAction {
    /// Opens a window and brings the (menu bar only) app to the front.
    @MainActor
    func bringUp(_ id: String) {
        callAsFunction(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuLabel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: iconName)
            .task {
                // First launch: go straight to setup.
                if model.needsSetup { openWindow.bringUp(WindowID.setup) }
            }
    }

    private var iconName: String {
        if model.isBusy { return "keyboard.badge.ellipsis" }
        if case .waiting = model.activity { return "keyboard.badge.ellipsis" }
        return model.allHere ? "keyboard.fill" : "keyboard"
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.needsSetup {
            Button("Set Up Monnect…") { openWindow.bringUp(WindowID.setup) }
        } else {
            status
            Divider()
            Button(model.allHere ? "Your Devices Are Here" : "Pull Input Here") { model.pull() }
                .disabled(model.allHere || model.isBusy)
                .keyboardShortcut("p")
            if case .waiting = model.activity {
                Button("Stop Waiting") { model.stopWaiting() }
            }
            Text(model.peerOnline ? "\(model.peerName): online" : "Other Mac: not found")
        }
        Divider()
        if let update = model.updateAvailable {
            Button("Update Available: v\(update.version)…") { NSWorkspace.shared.open(update.url) }
        }
        Button("Settings…") { openWindow.bringUp(WindowID.settings) }
            .keyboardShortcut(",")
        Button("Quit Monnect") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var status: some View {
        if let note = model.busyNote {
            Text(note)
        }
        switch model.activity {
        case .idle:
            EmptyView()
        case .claiming(let note):
            Text("Switching — \(note)")
        case .waiting(let devices):
            Text("Waiting for \(devices.names) — tap a key or click to wake it")
        case .gaveUp(let devices):
            Text("\(devices.names) didn't answer — pull again when awake")
        }
        if let notice = model.notice {
            Text(notice)
        }
        ForEach(model.config?.devices ?? []) { device in
            Text("\(device.name): \(locationText(device))")
        }
    }

    private func locationText(_ device: DeviceConfig) -> String {
        switch model.location(of: device) {
        case .here: return "here"
        case .otherMac: return "on \(model.peerName)"
        case .nowhere: return "not connected"
        }
    }
}

extension Array where Element == DeviceConfig {
    var names: String { map(\.name).joined(separator: ", ") }
}
