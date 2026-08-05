import GitPontCore
import SwiftUI
import UIKit

/// Provider-agnostic connect: sign in to GitHub with OAuth (device flow), or paste a
/// personal access token for any provider (GitHub, GitLab.com, self-hosted GitLab).
struct ConnectView: View {
    @Environment(AppModel.self) private var model

    @State private var choice: ProviderChoice = .github
    @State private var serverURL = ""
    @State private var token = ""
    /// Presents GitHub's device-flow page in an in-app Safari View Controller.
    @State private var showGitHubSignIn = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 44)).foregroundStyle(.tint)
                    Text("GitKittie Folder").font(.title.bold())
                    Text("Your files, backed by git.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            if let device = model.deviceAuth {
                deviceCodeSection(device)
            } else {
                demoSection
                providerSection
                if choice == .github { oauthSection }
                tokenSection
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                }
            }

        }
        .navigationTitle("Connect")
        // Copy the code as soon as it arrives so it is ready to paste, but do not open
        // GitHub yet — the page asks for the code immediately, and opening it first puts
        // the code behind the browser the user needs it for. They open it themselves.
        // The session going back to nil means sign-in finished, expired, or was
        // cancelled — close the browser if it is still up.
        .onChange(of: model.deviceAuth?.userCode) { _, userCode in
            if let userCode {
                UIPasteboard.general.string = userCode
            } else {
                showGitHubSignIn = false
            }
        }
        .sheet(isPresented: $showGitHubSignIn) {
            if let device = model.deviceAuth {
                SafariView(url: device.verificationURI).ignoresSafeArea()
            }
        }
    }

    // MARK: Demo

    /// First thing on the screen, before any sign-in option. Someone without a GitHub
    /// account — an App Store reviewer included — otherwise hits the sign-in wall and has
    /// no way past it. The demo is the full app against an in-memory repo, not a preview,
    /// so it is worth saying so plainly.
    private var demoSection: some View {
        Section {
            Button {
                model.loadDemo()
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Open the demo repositories").fontWeight(.semibold)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("No account?")
        } footer: {
            Text("Sample repositories with every feature working — browse folders, open and edit files, save changes, offline. No account, no sign-in.")
        }
    }

    // MARK: Provider

    private var providerSection: some View {
        Section("Provider") {
            Picker("Provider", selection: $choice) {
                ForEach(ProviderChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            if choice.needsServerURL {
                TextField("GitLab server URL (e.g. git.acme.com)", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
        }
    }

    // MARK: OAuth

    private var oauthSection: some View {
        Section {
            Button {
                Task { await model.startGitHubOAuth() }
            } label: {
                HStack {
                    Image(systemName: "person.badge.key.fill")
                    Text("Sign in with GitHub")
                    Spacer()
                    if model.isConnecting { ProgressView() }
                }
            }
            .disabled(model.isConnecting)
        } footer: {
            Text("Authorise on github.com without leaving the app — no token to create.")
        }
    }

    /// Device-flow UI: show the user code, open the verification page in-app, and wait.
    private func deviceCodeSection(_ device: GitOAuthDeviceSession) -> some View {
        Section("Sign in with GitHub") {
            VStack(spacing: 12) {
                Text("Copied. Open GitHub, paste this code, and confirm to authorise GitKittie Folder.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(device.userCode)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                HStack {
                    Button {
                        UIPasteboard.general.string = device.userCode
                    } label: { Label("Copy Code", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button {
                        showGitHubSignIn = true
                    } label: { Label("Open GitHub", systemImage: "safari") }
                        .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for authorisation…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelOAuth() }
                        .buttonStyle(.borderless)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Token

    private var tokenSection: some View {
        Section {
            SecureField("Personal access token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task { await model.connect(choice: choice, serverURL: serverURL, token: token) }
            } label: {
                if model.isConnecting && model.deviceAuth == nil {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Connect with Token").frame(maxWidth: .infinity)
                }
            }
            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || model.isConnecting)
        } header: {
            Text(choice == .github ? "Or use a token" : "Personal access token")
        } footer: {
            Text("Create a token with repository read/write scope in your provider's settings.")
        }
    }
}
