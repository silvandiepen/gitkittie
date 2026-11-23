import GitPontCore
import SwiftUI

/// Restoring → connect → the workspace.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isRestoring && !CaptureHooks.isDemo {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.window)
            } else if model.isConnected {
                WorkspaceView()
            } else {
                ConnectView()
            }
        }
        .alert("GitKittie Bud", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Connect a host account, or try the demo.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var choice: ProviderChoice = .github
    @State private var serverURL = ""
    @State private var token = ""
    @State private var isShowingToken = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image("BudMark")
                            .resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                        Text("GitKittie Bud")
                            .font(.largeTitle.weight(.semibold))
                        Text("Read history, compare changes line by line, and turn a part of any commit into a pull request — on your own git host.")
                            .foregroundStyle(.secondary)
                    }

                    if let session = model.deviceAuth {
                        deviceCode(session)
                    } else {
                        VStack(spacing: 12) {
                            Button {
                                Task { await model.startGitHubSignIn() }
                            } label: {
                                Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(model.isConnecting)

                            Button {
                                isShowingToken.toggle()
                            } label: {
                                Label("Use a token (GitHub or GitLab)", systemImage: "key")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button {
                                Task { await model.loadDemo() }
                            } label: {
                                Label("Try the demo", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityIdentifier("tryDemo")
                        }
                    }

                    if isShowingToken, model.deviceAuth == nil {
                        tokenForm
                    }

                    Text("GitKittie Bud has no account or server of its own. It talks straight to your git host, and your token stays in this device's keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.window.ignoresSafeArea())
        }
    }

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Host", selection: $choice) {
                ForEach(ProviderChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if choice.needsServerURL {
                TextField("gitlab.example.com", text: $serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            SecureField("Personal access token", text: $token)
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await model.connect(choice: choice, serverURL: serverURL, token: token) }
            } label: {
                if model.isConnecting { ProgressView() } else { Text("Connect").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || model.isConnecting)
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }

    /// The code to enter on GitHub, while GitKittie Bud waits for the go-ahead.
    private func deviceCode(_ session: GitOAuthDeviceSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter this code on GitHub")
                .font(.headline)
            Text(session.userCode)
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .accessibilityLabel("Code \(session.userCode.map(String.init).joined(separator: " "))")
            HStack {
                Button {
                    UIPasteboard.general.string = session.userCode
                    openURL(session.verificationURI)
                } label: {
                    Label("Copy and Open GitHub", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel", role: .cancel) { model.cancelSignIn() }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for GitHub…").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }
}
