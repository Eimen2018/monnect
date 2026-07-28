import SwiftUI

struct MonnectApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            Image(systemName: state.iconName)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if state.configMissing {
            Text("No config — run setup first")
        } else if state.blueutilMissing {
            Text("blueutil not installed (brew install blueutil)")
        } else {
            statusSection
            Divider()
            Button(state.allHere ? "Input Is Already Here" : "Pull Input Here") { state.pullInputHere() }
                .disabled(state.phase == .releasingPeer || isClaiming || state.allHere)
            Text(state.peerVisible ? "Other Mac: online" : "Other Mac: not found")
        }
        Divider()
        Button("Quit Monnect") { NSApplication.shared.terminate(nil) }
    }

    private var isClaiming: Bool {
        if case .claiming = state.phase { return true }
        return false
    }

    @ViewBuilder
    private var statusSection: some View {
        switch state.phase {
        case .idle:
            ForEach(state.config?.devices ?? []) { d in
                Text("\(d.name): \(state.connected[d.address] == true ? "here" : "away")")
            }
        case .releasingPeer:
            Text("Asking the other Mac to let go…")
        case .claiming(let note):
            Text("Switching — \(note)")
        case .error(let msg):
            Text(msg)
        }
    }
}
