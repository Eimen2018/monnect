import SwiftUI

/// Where the setup window starts: the full first-run flow, or straight to
/// showing a pairing code (Settings → Pair Another Mac).
enum SetupEntry { case welcome, pairOther }

struct SetupView: View {
    enum Role { case first, joining }
    enum Step: Equatable { case welcome, bluetooth, devices, pairOther, join, done }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome
    @State private var role: Role = .first
    @State private var selected: Set<String> = []
    @State private var host: PairingHost?
    @State private var code = ""
    @State private var address = ""
    @State private var showAddress = false
    @State private var joinError: String?
    @State private var joining = false
    @State private var pairedWith: String?
    @State private var launchAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(28)
        .frame(width: 480)
        .onAppear(perform: enter)
        .onDisappear { host?.stop() }
        // The window may already be open when Settings asks for a code, or
        // after a reset.
        .onChange(of: model.setupEntry) { _, entry in
            if entry == .pairOther { enter() }
        }
        .onChange(of: model.config == nil) { _, isNil in
            if isNil {
                host?.stop()
                step = .welcome
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .bluetooth: bluetooth
        case .devices: devices
        case .pairOther: pairOther
        case .join: join
        case .done: done
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Welcome to Monnect",
                   "Move your Magic Mouse and Keyboard between two Macs with one click. Set it up once on each Mac.")
            choice("Set Up My First Mac", "The Mac your mouse and keyboard work with right now.",
                   systemImage: "laptopcomputer") {
                role = .first
                goToBluetooth()
            }
            choice("Join My Other Mac", "Your other Mac is already set up and can show a pairing code.",
                   systemImage: "link") {
                role = .joining
                goToBluetooth()
            }
        }
    }

    private var bluetooth: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Allow Bluetooth", "Monnect needs Bluetooth access to pair and connect your devices.")
            BluetoothStep(permission: model.permission, onAllowed: advancePastBluetooth)
            backButton
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Choose Your Devices", "Pick the mouse, keyboard, or trackpad to move between your Macs.")
            DevicePicker(selected: $selected)
            HStack {
                backButton
                Spacer()
                Button("Continue", action: createSetup)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
    }

    private var pairOther: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Pair Your Other Mac",
                   "On your other Mac, install Monnect, open it, choose Join My Other Mac, and enter this code.")
            if let host {
                PairingHostView(host: host, peerOnline: model.peerOnline) { name in
                    pairedWith = name ?? pairedWith
                    finishPairing()
                }
            }
        }
    }

    private var join: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Join Your Other Mac",
                   "Type the code your other Mac is showing. (Already set up there? Settings → Pair Another Mac shows one.)")
            CodeField(code: $code, onComplete: runJoin)
            DisclosureGroup("Can't find your other Mac?", isExpanded: $showAddress) {
                TextField("Address shown under the code, e.g. 192.168.1.20:51234", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 4)
            }
            if let joinError {
                Text(joinError).foregroundStyle(.red)
            }
            HStack {
                backButton
                Spacer()
                if joining { ProgressView().controlSize(.small) }
                Button("Join", action: runJoin)
                    .buttonStyle(.borderedProminent)
                    .disabled(joining || PairingCrypto.normalize(code) == nil)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("You're All Set",
                   pairedWith.map { "This Mac and \($0) can now hand your devices back and forth." }
                       ?? "Set up your other Mac whenever you're ready: Settings → Pair Another Mac.")
            VStack(alignment: .leading, spacing: 6) {
                Label("Click the keyboard icon in the menu bar → Pull Input Here. Your devices follow in a few seconds.",
                      systemImage: "keyboard")
                Label("If one has gone to sleep, tap a key or click to wake it. Power-cycle one that still won't come.",
                      systemImage: "hand.tap")
            }
            .foregroundStyle(.secondary)
            Toggle("Open Monnect when I log in", isOn: $launchAtLogin)
            HStack {
                Spacer()
                Button("Done") {
                    model.setLaunchAtLogin(launchAtLogin)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Actions

    private func enter() {
        #if DEBUG
        // Jump straight to a step for screenshots: MONNECT_DEBUG_SETUP_STEP=join
        if ProcessInfo.processInfo.environment["MONNECT_DEBUG_SETUP_STEP"] == "join" {
            role = .joining
            step = .join
            return
        }
        #endif
        joinError = nil
        launchAtLogin = model.launchAtLogin || model.config == nil
        if model.setupEntry == .pairOther, model.config != nil {
            model.setupEntry = .welcome
            pairedWith = nil
            startHosting()
        } else if model.config != nil, step == .welcome {
            step = .done
        }
    }

    private func goToBluetooth() {
        model.permission.refresh()
        if model.permission.status == .allowed {
            advancePastBluetooth()
        } else {
            step = .bluetooth
        }
    }

    private func advancePastBluetooth() {
        step = role == .first ? .devices : .join
    }

    private func createSetup() {
        let devices = model.devices(for: selected)
        guard !devices.isEmpty else { return }
        do {
            try model.finishSetup(Config(key: Config.newKey(), devices: devices))
            startHosting()
        } catch {
            DiagLog.log("EVENT setup save failed: \(error)")
        }
    }

    private func startHosting() {
        guard let config = model.configForPairing() else { return }
        let host = PairingHost(payload: PairPayload(key: config.key, devices: config.devices,
                                                    devicesUpdatedAt: config.devicesUpdatedAt))
        self.host = host
        host.start()
        step = .pairOther
    }

    private func finishPairing() {
        host?.stop()
        step = .done
    }

    private func runJoin() {
        guard !joining else { return }
        joining = true
        joinError = nil
        Task {
            defer { joining = false }
            do {
                let result = try await PairingJoin.run(code: code, address: showAddress ? address : nil)
                guard let key = Data(base64Encoded: result.payload.key), key.count == 32 else { return }
                try model.finishSetup(Config(key: result.payload.key, devices: result.payload.devices,
                                             devicesUpdatedAt: result.payload.devicesUpdatedAt))
                pairedWith = result.hostName
                step = .done
            } catch {
                joinError = error.localizedDescription
                if (error as? PairingJoin.Failure) == .notFound { showAddress = true }
            }
        }
    }

    // MARK: Pieces

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choice(_ title: String, _ subtitle: String, systemImage: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var backButton: some View {
        Button("Back") {
            joinError = nil
            step = .welcome
        }
    }
}

/// Big, centered code entry that formats as you type and joins as soon
/// as the code is complete.
private struct CodeField: View {
    @Binding var code: String
    let onComplete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $code, prompt: Text("XXXXX-XXXXX"))
            .textFieldStyle(.plain)
            .font(.system(size: 30, weight: .semibold, design: .monospaced))
            .tracking(3)
            .multilineTextAlignment(.center)
            .focused($focused)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused ? 2 : 1))
            .onAppear { focused = true }
            .onSubmit(onComplete)
            .onChange(of: code) { _, typed in
                let formatted = PairingCrypto.formatTyping(typed)
                if formatted != typed {
                    code = formatted
                } else if PairingCrypto.normalize(formatted) != nil {
                    onComplete()
                }
            }
    }
}

private struct PairingHostView: View {
    @ObservedObject var host: PairingHost
    let peerOnline: Bool
    /// Called with the paired Mac's name, or nil when skipped.
    let onFinish: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch host.status {
            case .starting:
                ProgressView().frame(maxWidth: .infinity)
            case .waiting(let code, let addresses):
                Text(PairingCrypto.display(code))
                    .font(.system(size: 38, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your other Mac…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                if let first = addresses.first {
                    Text("If it can't find this Mac, enter this address there: \(first)")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            case .paired(let name):
                Label("Paired with \(name)", systemImage: "checkmark.circle.fill")
                    .font(.title3).foregroundStyle(.green)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
                Button("Show New Code") { host.start() }
            }
            HStack {
                Spacer()
                if case .paired(let name) = host.status {
                    Button("Continue") { onFinish(name) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(peerOnline ? "Done" : "Skip — Pair Later") { onFinish(nil) }
                }
            }
        }
    }
}

private struct BluetoothStep: View {
    @ObservedObject var permission: BluetoothPermission
    let onAllowed: () -> Void

    var body: some View {
        Group {
            if permission.status == .denied {
                Text("Bluetooth access is turned off for Monnect. Turn it on in System Settings → Privacy & Security → Bluetooth, then come back.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings") { NSWorkspace.shared.open(BluetoothPermission.settingsURL) }
                    Button("Check Again") { permission.refresh() }
                }
            } else {
                Button("Allow Bluetooth") { permission.request() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onChange(of: permission.status) { _, status in
            if status == .allowed { onAllowed() }
        }
        // Coming back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission.refresh()
        }
    }
}
