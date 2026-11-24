import SwiftUI

// The pieces the account sheets are built from, in the Tasks sheet style (the same family as
// GitKanban's SheetParts.swift; apps never import each other, so the few lines live here): a
// header that says what the sheet is for, then rows in a rounded panel.

/// The sheet's title and one or two sentences on what it is for.
struct SheetHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Rows in one rounded panel, a step lighter than the sheet, with the app's hairline.
struct SettingsPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// The hairline between two rows.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 14)
    }
}

/// A labelled field: the label on the left, the control filling the rest.
struct FieldRow<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 128, alignment: .leading)
                .foregroundStyle(.secondary)
            field
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// A plain-language problem under the form, in red, selectable so it can be copied.
struct SheetError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
