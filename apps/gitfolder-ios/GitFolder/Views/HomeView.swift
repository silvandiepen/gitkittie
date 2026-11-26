import SwiftUI

/// The home screen: repositories the user has added, shown like local folders. Tapping
/// one opens its file browser; "Add Repository" picks another from the account.
struct HomeView: View {
    let updates: AppUpdates
    @Environment(AppModel.self) private var model
    @State private var showAdd = false

    var body: some View {
        Group {
            if model.addedRepos.isEmpty {
                ContentUnavailableView {
                    Label("No Repositories", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a repository to browse and edit its files.")
                } actions: {
                    Button("Add Repository") { showAdd = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.addedRepos) { ref in
                        Button {
                            model.openRepo(ref)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.title3).foregroundStyle(.tint).frame(width: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(ref.name).foregroundStyle(.primary)
                                    Text(ref.namespace).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if ref.isPrivate {
                                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.removeAddedRepo(ref)
                            } label: { Label("Remove", systemImage: "minus.circle") }
                        }
                    }
                    .listRowBackground(Theme.panel)
                }
                .themedList()
            }
        }
        // A newer Folder in the App Store: Update opens its page there.
        .safeAreaInset(edge: .bottom) {
            if updates.offer != nil {
                UpdateAvailableNotice(updates: updates).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle("Repositories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if let login = model.connection?.login {
                        Text("Signed in as \(login)")
                    }
                    Button("Sign Out", role: .destructive) { model.signOut() }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack { AddRepositoryView() }.environment(model)
        }
    }
}
