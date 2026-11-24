import SwiftUI

/// Opening → the mail window, or what went wrong.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .opening:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.window)
        case .failed(let reason):
            StoreFailedView(reason: reason)
        case .ready:
            MailWindow()
        }
    }
}

/// Sidebar, message list, reader.
struct MailWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } content: {
            MessageListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            ReaderView()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }
}

/// The store could not be opened. Says why, and offers the one thing that can help.
private struct StoreFailedView: View {
    @Environment(AppModel.self) private var model
    let reason: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Your mail couldn’t be opened")
                .font(.title2.weight(.semibold))
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            Button("Try Again") { Task { await model.open() } }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }
}
