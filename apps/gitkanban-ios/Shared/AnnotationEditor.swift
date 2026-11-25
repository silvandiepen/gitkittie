import SwiftUI

/// Mark parts of a screenshot. The editor itself is `ImageMarkupEditor` (TasksUI), the same
/// on the Mac; this takes the iPhone's `SharedImage`.
struct AnnotationEditor: View {
    @Binding var image: SharedImage
    /// Problems the analysis found in the image, offered first as one-tap comments.
    var foundIssues: [String] = []

    var body: some View {
        ImageMarkupEditor(image: $image.image, foundIssues: foundIssues)
    }
}
