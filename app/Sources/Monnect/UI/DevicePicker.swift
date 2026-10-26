import SwiftUI

/// Pick which paired Bluetooth devices Monnect switches.
struct DevicePicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selected: Set<String>
    @State private var available: [DeviceConfig] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if available.isEmpty {
                Text("No paired Bluetooth devices found on this Mac.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(available) { device in
                            Toggle(isOn: binding(for: device.address)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name)
                                    Text(device.address).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            HStack {
                Text("Don't see it? Connect it once with its cable, then refresh.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", action: reload).controlSize(.small)
            }
        }
        .onAppear(perform: reload)
    }

    /// Paired devices here, plus configured ones that aren't paired with
    /// this Mac right now (they're on the other Mac).
    static func choices(paired: [DeviceConfig], configured: [DeviceConfig]) -> [DeviceConfig] {
        var seen = Set(paired.map(\.address))
        return paired + configured.filter { seen.insert($0.address).inserted }
    }

    static func looksLikeMagicDevice(_ d: DeviceConfig) -> Bool {
        let n = d.name.lowercased()
        return n.contains("magic") || n.contains("mouse") || n.contains("keyboard") || n.contains("trackpad")
    }

    private func reload() {
        available = Self.choices(paired: model.backend.pairedDevices(), configured: model.config?.devices ?? [])
        if selected.isEmpty {
            selected = Set(available.filter(Self.looksLikeMagicDevice).map(\.address))
        }
    }

    private func binding(for address: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(address) },
            set: { on in
                if on { selected.insert(address) } else { selected.remove(address) }
            })
    }
}

extension AppModel {
    func devices(for addresses: Set<String>) -> [DeviceConfig] {
        DevicePicker.choices(paired: backend.pairedDevices(), configured: config?.devices ?? [])
            .filter { addresses.contains($0.address) }
    }
}
