import GitKittieKit
import SwiftUI

/// Mark parts of a screenshot: drag a box, then say what is wrong with it. Comments come
/// from one tap on a suggestion (including the text found inside the box) or the keyboard.
struct AnnotationEditor: View {
    @Binding var image: SharedImage
    /// Problems the analysis found in the image, offered first as one-tap comments.
    var foundIssues: [String] = []
    @Environment(\.dismiss) private var dismiss

    @State private var preview: UIImage?
    @State private var textLines: [ImageTextLine] = []
    @State private var dragRect: CGRect?
    /// The annotation whose comment is being written.
    @State private var editingID: ImageAnnotation.ID?
    @FocusState private var commentFocused: Bool

    /// One-tap comments for the things that usually go wrong on a screen.
    private static let quickComments = [
        "Misaligned", "Cut off", "Wrong text", "Typo", "Wrong colour", "Too small",
        "Too much spacing", "Overlapping", "Should not be here", "Missing", "Does nothing when tapped"
    ]

    private var color: Color { Color(SharedImage.annotationColor) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                Divider()
                if let index = image.annotations.firstIndex(where: { $0.id == editingID }) {
                    commentBar(index: index)
                } else {
                    annotationList
                }
            }
            .navigationTitle("Annotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            preview = SharedImage.downsampled(image.data, maxPixel: 1600)
            textLines = await ImageTextReader.lines(in: image.data)
        }
    }

    private var canvas: some View {
        Group {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .overlay { GeometryReader { geometry in boxes(in: geometry.size) } }
            } else {
                ProgressView()
            }
        }
    }

    private func boxes(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in dragRect = rect(from: value.startLocation, to: value.location, in: size) }
                        .onEnded { value in
                            dragRect = nil
                            let rect = rect(from: value.startLocation, to: value.location, in: size)
                            // Ignore accidental taps: a box needs some size.
                            guard rect.width * size.width > 16, rect.height * size.height > 16 else { return }
                            let annotation = ImageAnnotation(rect: rect, comment: "")
                            image.annotations.append(annotation)
                            editingID = annotation.id
                        }
                )
                .accessibilityIdentifier("annotationCanvas")
            ForEach(Array(image.annotations.enumerated()), id: \.element.id) { index, annotation in
                box(annotation.rect, number: index + 1, in: size)
                    .onTapGesture { editingID = annotation.id }
            }
            if let dragRect { box(dragRect, number: nil, in: size) }
        }
    }

    private func box(_ rect: CGRect, number: Int?, in size: CGSize) -> some View {
        let frame = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                           width: rect.width * size.width, height: rect.height * size.height)
        return RoundedRectangle(cornerRadius: 4)
            .stroke(color, lineWidth: 2)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .frame(width: frame.width, height: frame.height)
            .overlay(alignment: .topLeading) {
                if let number {
                    Text("\(number)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(color, in: Circle())
                        .offset(x: -10, y: -10)
                }
            }
            .offset(x: frame.minX, y: frame.minY)
    }

    private func rect(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        func clamp(_ value: CGFloat, _ limit: CGFloat) -> CGFloat { min(max(value, 0), limit) }
        let x1 = clamp(start.x, size.width), x2 = clamp(end.x, size.width)
        let y1 = clamp(start.y, size.height), y2 = clamp(end.y, size.height)
        return CGRect(x: min(x1, x2) / size.width, y: min(y1, y2) / size.height,
                      width: abs(x2 - x1) / size.width, height: abs(y2 - y1) / size.height)
    }

    /// Suggestions for the box being commented: the text inside it first, then the usual suspects.
    private func suggestions(for annotation: ImageAnnotation) -> [String] {
        let inside = ImageTextReader.text(in: annotation.rect, of: textLines)
        var result: [String] = []
        if !inside.isEmpty {
            let quoted = inside.count > 40 ? String(inside.prefix(40)) + "…" : inside
            result += ["“\(quoted)” is wrong", "Typo in “\(quoted)”"]
        }
        return foundIssues + result + Self.quickComments
    }

    private func commentBar(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions(for: image.annotations[index]), id: \.self) { suggestion in
                        Button(suggestion) {
                            image.annotations[index].comment = suggestion
                            finishEditing()
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color, in: Circle())
                TextField("What is wrong here?", text: $image.annotations[index].comment, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($commentFocused)
                    .submitLabel(.done)
                    .onSubmit(finishEditing)
                    .accessibilityIdentifier("annotationComment")
                Button(role: .destructive) {
                    image.annotations.remove(at: index)
                    editingID = nil
                } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Remove annotation")
                Button("OK", action: finishEditing).fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }

    private func finishEditing() {
        commentFocused = false
        editingID = nil
    }

    @ViewBuilder private var annotationList: some View {
        if image.annotations.isEmpty {
            Text("Drag on the image to mark a part of it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(16)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(image.annotations.enumerated()), id: \.element.id) { index, annotation in
                        Button { editingID = annotation.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(color, in: Circle())
                                Text(annotation.comment.isEmpty ? "No comment yet" : annotation.comment)
                                    .foregroundStyle(annotation.comment.isEmpty ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 160)
        }
    }
}
