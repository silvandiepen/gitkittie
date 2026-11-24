import GitKittieKit
import SwiftUI

// A question in a review request, answered in place. Shared by the Mac and iPhone apps: the
// question as a heading with its Markdown detail, every option a full-width row (a radio
// circle for one answer, a checkbox for several), "Other" with a text field where the agent
// allows it, an optional comment, and Answer. Once answered it shows what was chosen, by
// whom and when, and Change Answer until the agent has acted on it.

struct ReviewQuestionView: View {
    let question: ReviewQuestion
    /// A write is under way: the buttons wait.
    var isSaving = false
    /// Writes the answer (option ids in option order, an own answer, a comment); returns
    /// whether it was written.
    let onAnswer: (_ choices: [String], _ other: String?, _ comment: String?) async -> Bool
    /// After an answer was written, e.g. to move on to the next question.
    var onAnswered: (() -> Void)?

    @State private var editing = false
    @State private var choices: Set<String> = []
    @State private var otherOn = false
    @State private var otherText = ""
    @State private var comment = ""
    @State private var submitting = false
    @FocusState private var otherFocused: Bool

    /// Choosing, rather than looking at an answer.
    private var isOpen: Bool { !question.isAnswered || editing }
    private var single: Bool { question.select == .one }
    private var ownAnswer: String { otherText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        if otherOn && ownAnswer.isEmpty { return false }
        return !choices.isEmpty || otherOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading
            options
            if isOpen { answerControls } else { answeredLine }
            if !question.comments.isEmpty { comments }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reviewQuestion-\(question.id)")
    }

    // MARK: Parts

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(single ? "Choose one" : "Choose any that apply")
                .font(.subheadline).foregroundStyle(.secondary)
            if let detail = question.detail {
                MarkdownPage(markdown: detail).padding(.top, 4)
            }
        }
    }

    private var options: some View {
        VStack(spacing: 0) {
            ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { divider }
                row(label: option.label, detail: option.detail, selected: isChosen(option.id),
                    identifier: "reviewOption-\(question.id)-\(option.id)") { toggle(option.id) }
            }
            if question.allowsOther {
                if !question.options.isEmpty { divider }
                otherRow
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 48)
    }

    /// One option: its mark, its label in body weight and what it means below. The chosen
    /// ones have a tinted fill.
    private func row(label: String, detail: String?, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                mark(selected)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.body).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(MarkdownPage.inline(detail))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // An explicit rectangle: a plain colour fills the button's own rounded shape on iOS 26.
        .background(Rectangle().fill(selected ? Theme.accent.opacity(0.16) : Color.clear))
        .allowsHitTesting(isOpen && !isSaving)
        .opacity(!isOpen && !selected ? 0.6 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(isOpen ? (single ? "Chooses this answer" : "Adds or removes this answer") : "")
        .accessibilityIdentifier(identifier)
    }

    private func mark(_ selected: Bool) -> some View {
        let symbol = single ? (selected ? "largecircle.fill.circle" : "circle") : (selected ? "checkmark.square.fill" : "square")
        return Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var otherRow: some View {
        let selected = isOpen ? otherOn : question.answerOther != nil
        VStack(alignment: .leading, spacing: 0) {
            row(label: "Other", detail: isOpen ? nil : question.answerOther, selected: selected,
                identifier: "reviewOption-\(question.id)-other") { toggleOther() }
            if isOpen && otherOn {
                TextField("Your answer", text: $otherText, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($otherFocused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.window, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.leading, 48).padding(.trailing, 14).padding(.bottom, 12)
                    .background(Rectangle().fill(Theme.accent.opacity(0.16)))
                    .accessibilityIdentifier("reviewOtherField-\(question.id)")
            }
        }
    }

    private var answerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Comment for the agent (optional)", text: $comment, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                .accessibilityIdentifier("reviewQuestionComment-\(question.id)")
            HStack(spacing: 10) {
                Button { submit() } label: {
                    Group {
                        if submitting { ProgressView().controlSize(.small) } else { Text(editing ? "Save Answer" : "Answer") }
                    }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 96, minHeight: 22)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!canSubmit || isSaving || submitting)
                .accessibilityIdentifier("reviewAnswerButton-\(question.id)")
                if editing {
                    Button("Cancel") { editing = false; comment = "" }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var answeredLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label {
                Text(answeredText)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .accessibilityIdentifier("reviewAnswered-\(question.id)")
            Spacer(minLength: 8)
            if question.handledAt == nil {
                Button("Change Answer") { startEditing() }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                    .accessibilityIdentifier("reviewChangeAnswer-\(question.id)")
            }
        }
    }

    private var answeredText: String {
        var text = "Answered"
        if let by = question.answeredBy { text += " by \(by)" }
        if let at = question.answeredAt { text += ", \(ReviewFormat.relative(at))" }
        if question.handledAt != nil { text += ". The agent has acted on it." }
        return text
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(question.comments.enumerated()), id: \.offset) { _, comment in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(comment.by) · \(ReviewFormat.relative(comment.at))").font(.caption).foregroundStyle(.secondary)
                    Text(comment.text).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Choosing

    private func isChosen(_ id: String) -> Bool {
        isOpen ? choices.contains(id) : question.answer.contains(id)
    }

    private func toggle(_ id: String) {
        if single {
            choices = [id]
            otherOn = false
            otherFocused = false
        } else if choices.contains(id) {
            choices.remove(id)
        } else {
            choices.insert(id)
        }
    }

    private func toggleOther() {
        if single {
            choices = []
            otherOn = true
        } else {
            otherOn.toggle()
        }
        otherFocused = otherOn
    }

    private func startEditing() {
        choices = Set(question.answer)
        otherOn = question.answerOther != nil
        otherText = question.answerOther ?? ""
        comment = ""
        editing = true
    }

    private func submit() {
        guard canSubmit else { return }
        let picked = question.options.map(\.id).filter(choices.contains)
        let own = otherOn ? ownAnswer : nil
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        submitting = true
        Task {
            let written = await onAnswer(picked, own, note.isEmpty ? nil : note)
            submitting = false
            if written {
                editing = false
                comment = ""
                onAnswered?()
            }
        }
    }
}
