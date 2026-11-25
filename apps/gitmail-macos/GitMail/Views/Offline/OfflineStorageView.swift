import MailStore
import SwiftUI

/// Offline storage (GKM-036): what partial messages left at the provider, what the cache holds
/// and may give back, and what pins are still waiting to download.
struct OfflineStorageView: View {
    static let windowID = "offline-storage"
    @Environment(AppModel.self) private var model
    @State private var storage: OfflineStorage?
    @State private var freed: EvictionResult?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Offline Storage").font(.title3.weight(.semibold))
            Text("Attachments larger than \(MessageDate.byteCount(model.onDemandThreshold)) stay at your provider until you open them, or until you keep their message, conversation or space offline. Your mail folder always holds complete originals; only attachments downloaded for partly downloaded messages are kept here, and they can be downloaded again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let storage {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Messages with attachments not downloaded", "\(storage.partialMessages)")
                    row("Not downloaded", MessageDate.byteCount(Int(storage.notDownloadedBytes)))
                    row("Downloaded attachments kept here", "\(storage.cachedParts), \(MessageDate.byteCount(Int(storage.cacheBytes)))")
                    row("Of those, can be freed", MessageDate.byteCount(Int(storage.evictableBytes)))
                    row("Kept offline, waiting for a connection", "\(storage.pinnedWaiting)")
                }
                .font(.callout)
            } else {
                ProgressView().controlSize(.small)
            }
            if let freed {
                Text("Freed \(MessageDate.byteCount(Int(freed.removedBytes))) (\(freed.removedParts) attachments). They download again when opened.")
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Free Up Space") {
                    Task {
                        working = true
                        freed = await model.freeUpOfflineSpace(keeping: 0)
                        storage = await model.offlineStorage()
                        working = false
                    }
                }
                .disabled(working || (storage?.evictableBytes ?? 0) == 0)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { storage = await model.offlineStorage() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// The menu item that opens ``OfflineStorageView``.
struct OfflineStorageCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Offline Storage…") { openWindow(id: OfflineStorageView.windowID) }
    }
}
