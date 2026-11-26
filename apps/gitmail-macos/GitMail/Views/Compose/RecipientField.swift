import MailCore
import SwiftUI

/// Addresses as tokens, with a text field after them. Typing a comma, Return or leaving the
/// field turns what was typed into tokens; Delete in an empty field removes the last one.
/// A token that is not a valid address is shown in orange and blocks sending.
struct RecipientField: View {
    @Bindable var compose: ComposeModel
    let field: ComposeModel.Field
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(
            get: { compose.pending[field, default: ""] },
            set: { newValue in
                compose.pending[field] = newValue
                if newValue.hasSuffix(",") || newValue.hasSuffix(";") { compose.commitPending(field) }
            }
        )
    }

    var body: some View {
        FlowLayout(spacing: 6, stretchesLast: true) {
            ForEach(compose.recipients(field), id: \.self) { address in
                RecipientToken(address: address, isValid: compose.isValid(address)) {
                    compose.remove(address, from: field)
                }
            }
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.body)
                .frame(minWidth: 160)
                .focused($focused)
                .onSubmit { compose.commitPending(field) }
                .onKeyPress(.delete) {
                    guard text.wrappedValue.isEmpty, let last = compose.recipients(field).last else { return .ignored }
                    compose.remove(last, from: field)
                    return .handled
                }
                .accessibilityLabel(label)
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { compose.commitPending(field) }
        }
    }

    private var label: String {
        switch field {
        case .to: "To"
        case .cc: "Cc"
        case .bcc: "Bcc"
        }
    }
}

private struct RecipientToken: View {
    let address: MailAddress
    let isValid: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Not a colour alone: an invalid address carries a mark too.
            if !isValid { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
            Text(address.displayName)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(address.address)")
        }
        // One element with Remove as its action; an invalid address says so, not only in orange.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(address.name.map { "\($0), \(address.address)" } ?? address.address)
        .accessibilityValue(isValid ? "" : "Not a valid address")
        .accessibilityAction(named: "Remove", remove)
        .font(.callout)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(fill, in: Capsule())
        .help(address.name.map { "\($0) <\(address.address)>" } ?? address.address)
    }

    private var fill: Color {
        isValid ? Theme.accent.opacity(0.18) : Color.orange.opacity(0.25)
    }
}

/// Lays children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    /// The last child (a text field after tokens) takes the rest of its row.
    var stretchesLast = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let width = index == row.indices.last && row.stretchLast ? max(size.width, bounds.maxX - x) : size.width
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        /// The last child (the text field) takes the rest of the row.
        var stretchLast = false
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        if stretchesLast, !rows.isEmpty { rows[rows.count - 1].stretchLast = true }
        return rows
    }
}
