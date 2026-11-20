import NodCore
import SwiftUI

/// Sets up the connection to Nod in three steps: where Nod is, the key for it, and a check
/// that everything the app needs from Nod works. Nothing is saved before that check passes.
struct ConnectionSetupScreen: View {
    @Environment(\.dismiss) private var dismiss

    /// Shown by itself when the app starts without a connection, with a way to the stand-in.
    var isWelcome = false

    @State private var addressText: String
    @State private var address: URL?
    @State private var problem: String?
    @State private var isChecking = false
    @FocusState private var addressFocused: Bool

    init(currentAddress: URL? = nil, isWelcome: Bool = false) {
        _addressText = State(initialValue: currentAddress?.absoluteString ?? "")
        self.isWelcome = isWelcome
    }

    var body: some View {
        NavigationStack {
            Form {
                if isWelcome {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Connect to Your Nod")
                                .font(.title2.bold())
                            Text("This app is the voice and the chat for your own Nod. It needs to know where your Nod is and the key for it.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    TextField("nod.example.com", text: $addressText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.continue)
                        .focused($addressFocused)
                        .onSubmit(checkAddress)
                        .accessibilityLabel("Address of Nod")
                } header: {
                    Text("Step 1 of 3")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else if isChecking {
                        Text("Looking for Nod at this address…")
                    } else {
                        Text("The HTTPS address at which you open Nod in a browser, for example the one of your Cloudflare Tunnel.")
                    }
                }
                if isWelcome {
                    Section {
                        Button("Try the Demo Assistant Instead") { dismiss() }
                    } footer: {
                        Text("A stand-in inside the app answers, so nothing leaves this device. The connection can be set up later in Settings.")
                    }
                }
            }
            .navigationTitle("Nod Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isChecking {
                        ProgressView()
                    } else {
                        Button("Continue", action: checkAddress)
                            .disabled(addressText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationDestination(item: $address) { address in
                KeyStep(address: address) { dismiss() }
            }
            .onAppear { addressFocused = !isWelcome || !addressText.isEmpty }
            .onChange(of: addressText) { problem = nil }
        }
    }

    private func checkAddress() {
        guard !isChecking else { return }
        let url: URL
        switch NodAddress.parse(addressText) {
        case .success(let parsed):
            url = parsed
        case .failure(.empty):
            problem = "Enter the address of Nod."
            return
        case .failure(.notSecure(let scheme)):
            problem = "An address that starts with \(scheme):// cannot be used. Nod is reached over https:// only, so that the key is never sent unprotected."
            return
        case .failure(.notAnAddress):
            problem = "This is not an address. It should look like nod.example.com."
            return
        }
        problem = nil
        isChecking = true
        Task {
            let check = await NodConnectionCheck.address(url)
            isChecking = false
            switch check {
            case .success: address = url
            case .failure(let error): problem = error.message
            }
        }
    }
}

/// An address with a key that Nod accepted, on its way to the final check. Held in memory
/// only, for as long as the setup is open.
private struct Credentials: Hashable {
    var address: URL
    var key: String
}

/// The second step: the key that lets this app talk to the agent.
private struct KeyStep: View {
    var address: URL
    var done: () -> Void

    @State private var key = ""
    @State private var problem: String?
    @State private var isChecking = false
    @State private var accepted: Credentials?
    @FocusState private var keyFocused: Bool

    var body: some View {
        Form {
            Section {
                LabeledContent("Address", value: address.absoluteString)
            }
            Section {
                SecureField("Key", text: $key)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($keyFocused)
                    .onSubmit(check)
                    .accessibilityLabel("Authentication key")
            } header: {
                Text("Step 2 of 3")
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                } else if isChecking {
                    Text("Asking Nod whether it accepts the key…")
                } else {
                    Text("Nod's authentication token (NOD_AUTH_TOKEN). It is kept in this device's Keychain, sent only to the address above, and not shown again.")
                }
            }
        }
        .navigationTitle("Authentication Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isChecking {
                    ProgressView()
                } else {
                    Button("Continue", action: check).disabled(trimmedKey.isEmpty)
                }
            }
        }
        .navigationDestination(item: $accepted) { credentials in
            CheckStep(credentials: credentials, done: done)
        }
        .onAppear { keyFocused = true }
        .onChange(of: key) { problem = nil }
    }

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func check() {
        guard !trimmedKey.isEmpty, !isChecking else { return }
        guard !trimmedKey.contains(where: \.isWhitespace) else {
            problem = "A key has no spaces in it."
            return
        }
        problem = nil
        isChecking = true
        let key = trimmedKey
        Task {
            let check = await NodConnectionCheck.key(key, at: address)
            isChecking = false
            switch check {
            case .success: accepted = Credentials(address: address, key: key)
            case .failure(let error): problem = error.message
            }
        }
    }
}

/// The third step: asks Nod for everything the app will need, and saves the connection only
/// when all of it worked. The setup cannot be finished before that.
private struct CheckStep: View {
    @Environment(AppState.self) private var app
    var credentials: Credentials
    var done: () -> Void

    private enum Outcome: Equatable {
        case waiting, running, passed, failed(String)
    }

    @State private var outcomes: [Outcome] = Array(repeating: .waiting, count: Self.parts.count + 1)
    @State private var run: Task<Void, Never>?

    private static let parts = NodConnectionCheck.Part.allCases

    private var isRunning: Bool { outcomes.contains(.running) }
    private var hasPassed: Bool { outcomes.allSatisfy { $0 == .passed } }
    private var failure: String? {
        for outcome in outcomes { if case .failed(let reason) = outcome { return reason } }
        return nil
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(Self.parts.enumerated()), id: \.offset) { index, part in
                    row(Self.title(of: part), outcomes[index])
                }
                row("The key is saved in the Keychain", outcomes[Self.parts.count])
            } header: {
                Text("Step 3 of 3")
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                } else if hasPassed {
                    Text("Everything works. Nothing was sent to the agent for this check.")
                } else {
                    Text("Checking that everything the app needs from Nod works. Nothing is sent to the agent.")
                }
            }
            if failure != nil {
                Section {
                    Button("Check Again", action: start)
                } footer: {
                    Text("The connection is not saved. Go back to change the address or the key.")
                }
            }
        }
        .navigationTitle("Checking")
        .navigationBarTitleDisplayMode(.inline)
        // Once everything is saved there is nothing to go back to.
        .navigationBarBackButtonHidden(isRunning || hasPassed)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isRunning {
                    ProgressView()
                } else {
                    Button("Done", action: done).disabled(!hasPassed)
                }
            }
        }
        .onAppear { if run == nil { start() } }
        .onDisappear { run?.cancel() }
    }

    private func row(_ title: String, _ outcome: Outcome) -> some View {
        HStack(spacing: 12) {
            Group {
                switch outcome {
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running:
                    ProgressView()
                case .passed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 24)
            Text(title)
                .foregroundStyle(outcome == .waiting ? .secondary : .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Self.spoken(outcome))
    }

    private static func title(of part: NodConnectionCheck.Part) -> String {
        switch part {
        case .address: return "Nod answers at the address"
        case .key: return "The key is accepted"
        case .conversation: return "The conversation can be read"
        case .liveUpdates: return "Replies arrive live"
        }
    }

    private static func spoken(_ outcome: Outcome) -> String {
        switch outcome {
        case .waiting: return "Not checked yet"
        case .running: return "Being checked"
        case .passed: return "Works"
        case .failed: return "Does not work"
        }
    }

    private func start() {
        run?.cancel()
        outcomes = Array(repeating: .waiting, count: Self.parts.count + 1)
        run = Task {
            for (index, part) in Self.parts.enumerated() {
                outcomes[index] = .running
                let result = await NodConnectionCheck.verify(part, key: credentials.key, at: credentials.address)
                guard !Task.isCancelled else { return }
                if case .failure(let error) = result {
                    outcomes[index] = .failed(error.message)
                    return
                }
                outcomes[index] = .passed
            }
            let last = Self.parts.count
            outcomes[last] = .running
            do {
                try app.saveConnection(address: credentials.address, key: credentials.key)
                outcomes[last] = .passed
            } catch {
                outcomes[last] = .failed("The key could not be saved in the Keychain.")
            }
        }
    }
}
