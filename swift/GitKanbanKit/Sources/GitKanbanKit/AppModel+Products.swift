import Foundation
import GitKittieKit

// The products of the open board (see `BoardProduct`): read from its README, shown in the
// sidebar, used to filter the board, and named on tasks with `product:`.

extension AppModel {
    /// Read the open board's products from its README.
    func loadProducts() async {
        guard let source, let folder = activeBoardFolder, let repo = activeRepo else { products = []; return }
        let key = "\(repo.id)|\(folder)"
        let readme = (try? await source.readText(BoardDocs.join(folder, BoardDocs.aboutPath))) ?? ""
        // The board may have been switched while this was reading.
        guard activeRepo?.id == repo.id, activeBoardFolder == folder else { return }
        products = BoardStore.products(inReadme: readme)
        if let filterProduct, !products.contains(where: { $0.id == filterProduct }) { self.filterProduct = nil }
        boardCache[key]?.products = products
    }

    /// How many tasks of the loaded board each product has.
    public func taskCount(of product: BoardProduct) -> Int {
        allCards.reduce(0) { $0 + ($1.fields.product == product.id ? 1 : 0) }
    }

    /// Write the board's product list into its README. Every other line stays as it is.
    /// A product that got a new id (it was renamed) takes its tasks along, in one commit.
    @discardableResult
    public func saveProducts(_ list: [BoardProduct], renamed: [FieldMerge] = []) async -> Bool {
        guard let source, let folder = activeBoardFolder, let project = selectedProject else { return false }
        errorMessage = nil
        let path = BoardDocs.join(folder, BoardDocs.aboutPath)
        do {
            let readme = try await source.readText(path)
            let updated = ReadmePatch.apply(BoardStore.renderProducts(list), to: readme, keys: ["products"])
            if updated != readme { try await source.write(path: path, text: updated, message: "Update products") }
        } catch { errorMessage = error.localizedDescription; return false }
        products = list
        if !renamed.isEmpty { await mergeValues(renamed, in: project) }
        return errorMessage == nil
    }
}
