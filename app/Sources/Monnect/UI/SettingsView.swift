import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var editingDevices = false
    @State private var editSelection: Set<String> = []
    @State private var confirmingReset = false

    var body: some View {
        Form {
            if let config = model.config {
                Section("Devices") {
                    ForEach(config.devices) { device in
                        LabeledContent(device.name, value: locationText(device))
                    }
                    Button("Change Devices…") {
                        editSelection = Set(config.devices.map(\.address))
                        editingDevices = true
                    }
                }

                Section("Other Mac") {
                    LabeledContent(model.peerOnline ? model.peerName : "Other Mac",
                                   value: model.peerOnline ? "Online" : "Not found")
                    if config.migratedFromV1 {
                        Text("These Macs were paired by Monnect 0.1. Pair again to replace the old key with a fresh one.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Pair Another Mac…") {
                        model.setupEntry = .pairOther
                        openWindow.bringUp(WindowID.setup)
                    }
                }

                Section("Behavior") {
                    Toggle("Open Monnect when I log in", isOn: Binding(
                        get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    Toggle(isOn: Binding(get: { config.releaseOnLidClose },
                                         set: { model.setReleaseOnLidClose($0) })) {
                        Text("Let go of devices when the lid closes")
                        Text("Only while your other Mac is awake to take them.")
                    }
                    Toggle("Check for updates daily", isOn: Binding(
                        get: { config.checkForUpdates }, set: { model.setCheckForUpdates($0) }))
                }
            } else {
                Section {
                    Text("Monnect isn't set up yet.")
                    Button("Set Up Monnect…") { openWindow.bringUp(WindowID.setup) }
                }
            }

            Section("Troubleshooting") {
                Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DiagLog.url]) }
                if model.config != nil {
                    Button("Reset Monnect…", role: .destructive) { confirmingReset = true }
                }
                LabeledContent("Version", value: UpdateChecker.currentVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $editingDevices) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose Devices").font(.headline)
                Text("Your other Mac picks up the change automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                DevicePicker(selected: $editSelection)
                HStack {
                    Spacer()
                    Button("Cancel") { editingDevices = false }
                    Button("Save") {
                        model.setDevices(model.devices(for: editSelection))
                        editingDevices = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editSelection.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
        .confirmationDialog("Reset Monnect?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                model.resetSetup()
                openWindow.bringUp(WindowID.setup)
            }
        } message: {
            Text("This Mac forgets its devices and its pairing with your other Mac. Your devices stay where they are.")
        }
    }

    private func locationText(_ device: DeviceConfig) -> String {
        switch model.location(of: device) {
        case .here: return "Here"
        case .otherMac: return "On \(model.peerName)"
        case .nowhere: return "Not connected"
        }
    }
}
