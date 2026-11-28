import Foundation
import GitKittieKit

// Checking one browser check (ReviewSpec § 3.4, § 3.5): the size and appearance on screen, the
// checklist answered for it, screenshots and the check's decision. The Mac's Check in Browser
// window and the iPhone's full-screen check both run on this.
//
// Answers show at once and are written a second after the last one, together (ticking through
// a checklist is one write, not one per line). A decision, a screenshot or leaving writes what
// is still waiting first.

@MainActor
@Observable
public final class ReviewCheckSession {
    public let ref: ReviewRef
    public let checkID: String
    private let model: AppModel

    /// How long answers wait for more before they are written.
    public var debounce: Duration = .seconds(1)

    /// The size on screen, as an index into `sizes`.
    public var sizeIndex = 0
    /// The appearance on screen; `nil` when the check lists none (the page's own).
    public var appearance: CheckAppearance?
    /// The viewport the page is really shown at ("402x874"), recorded with answers and
    /// screenshots. The screen sets it once it has laid the page out.
    public var viewport: String?
    /// Something is being written.
    public private(set) var isWriting = false

    private struct Pending: Equatable {
        var result: CheckAnswerResult?
        var note: String?
        var viewport: String?
    }

    /// Answers given and not written yet, by result key, then checklist line.
    private var pending: [String: [String: Pending]] = [:]
    private var flushTask: Task<Void, Never>?

    public init(model: AppModel, ref: ReviewRef, checkID: String) {
        self.model = model
        self.ref = ref
        self.checkID = checkID
        appearance = storedCheck?.appearance.first
        if let check = storedCheck, let first = check.resultKeys.first(where: { check.progress($0).answered < check.progress($0).total }) {
            select(key: first)
        }
    }

    public var request: ReviewRequest? { model.reviewRequest(ref) }

    /// The check as written in the request.
    public var storedCheck: ReviewCheck? { request?.checks.first { $0.id == checkID } }

    /// The check with the answers not written yet laid over it: what the screens draw.
    public var check: ReviewCheck? {
        guard var check = storedCheck else { return nil }
        for (key, lines) in pending {
            var result = check.results[key] ?? CheckResult()
            for (line, answer) in lines {
                if let value = answer.result {
                    result.answers[line] = CheckAnswer(result: value, note: answer.note)
                } else {
                    result.answers[line] = nil
                }
                if let viewport = answer.viewport { result.viewport = viewport }
            }
            check.results[key] = result
        }
        return check
    }

    public var hasUnwrittenAnswers: Bool { pending.values.contains { !$0.isEmpty } }

    // MARK: Size and appearance

    public var sizes: [CheckSize] { storedCheck?.effectiveSizes ?? [CheckSize(id: CheckSize.defaultID, label: "Default")] }
    public var appearances: [CheckAppearance] { storedCheck?.appearance ?? [] }
    public var size: CheckSize { sizes[min(max(sizeIndex, 0), sizes.count - 1)] }

    /// Where the answers on screen are stored: `phone`, or `phone.dark`.
    public var key: String { ReviewCheck.resultKey(size: size.id, appearance: appearances.isEmpty ? nil : appearance) }

    /// Go to a result key (a cell of the grid).
    public func select(key: String) {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        if let index = sizes.firstIndex(where: { $0.id == parts[0] }) { sizeIndex = index }
        if parts.count > 1, let look = CheckAppearance(rawValue: parts[1]) { appearance = look }
    }

    /// The cells in order (each size, in each appearance): what Next and Previous walk.
    public var keys: [String] { storedCheck?.resultKeys ?? [key] }

    public var hasNext: Bool { (keys.firstIndex(of: key) ?? keys.count) < keys.count - 1 }
    public var hasPrevious: Bool { (keys.firstIndex(of: key) ?? 0) > 0 }

    public func next() {
        guard let index = keys.firstIndex(of: key), index + 1 < keys.count else { return }
        select(key: keys[index + 1])
    }

    public func previous() {
        guard let index = keys.firstIndex(of: key), index > 0 else { return }
        select(key: keys[index - 1])
    }

    // MARK: Answers

    /// Someone else's request: you may look, not answer or decide.
    public var isReadOnly: Bool { request.map(model.isReadOnly) ?? true }
    public var readOnlyNotice: String? { request.flatMap(model.readOnlyNotice) }

    /// The answer to a line at the size on screen.
    public func answer(_ line: String) -> CheckAnswer? { check?.results[key]?.answers[line] }

    public var progress: (answered: Int, total: Int) { check?.progress(key) ?? (0, 0) }

    /// The screenshot of the size on screen, relative to the request folder.
    public var screenshot: String? { storedCheck?.results[key]?.screenshot }

    /// Answer a line at the size on screen (`nil` takes the answer back). A note needs its text.
    /// Returns whether the answer was taken.
    @discardableResult
    public func setAnswer(_ line: String, _ result: CheckAnswerResult?, note: String? = nil) -> Bool {
        guard !isReadOnly else {
            model.errorMessage = readOnlyNotice
            return false
        }
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = (text?.isEmpty ?? true) ? nil : text
        if result == .note, trimmed == nil { return false }
        pending[key, default: [:]][line] = Pending(result: result, note: trimmed, viewport: viewport)
        scheduleFlush()
        return true
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let delay = debounce
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Write the answers given so far, one write per size. Returns whether all were written;
    /// what could not be written stays, to be written with the next answer.
    @discardableResult
    public func flush() async -> Bool {
        flushTask?.cancel()
        flushTask = nil
        guard hasUnwrittenAnswers, let request, let check = storedCheck else { return true }
        let batch = pending
        pending = [:]
        isWriting = true
        defer { isWriting = false }
        var ok = true
        for key in batch.keys.sorted() {
            guard let lines = batch[key], !lines.isEmpty else { continue }
            let viewport = lines.values.compactMap(\.viewport).last
            let answers = lines.keys.sorted().map { (line: $0, result: lines[$0]!.result, note: lines[$0]!.note) }
            let fresh = model.reviewRequest(ref) ?? request
            if !(await model.answerCheck(fresh, check: check, key: key, answers: answers, viewport: viewport)) {
                ok = false
                // Keep what failed, unless it was answered again meanwhile.
                for (line, answer) in lines where pending[key]?[line] == nil {
                    pending[key, default: [:]][line] = answer
                }
            }
        }
        return ok
    }

    // MARK: Decision and screenshot

    /// What Changes starts with: the failed and noted lines.
    public var changesDraft: String { check?.changesDraft ?? "" }

    /// Decide the check (Changes needs a comment), after writing the answers still waiting.
    @discardableResult
    public func decide(_ status: ReviewStatus, comment: String? = nil) async -> Bool {
        guard await flush(), let request = model.reviewRequest(ref), let check = storedCheck else { return false }
        isWriting = true
        defer { isWriting = false }
        return await model.decideCheck(request, check: check, status: status, comment: comment)
    }

    /// Store a screenshot of the size on screen, after writing the answers still waiting.
    @discardableResult
    public func saveScreenshot(_ png: Data) async -> Bool {
        _ = await flush()
        guard let request = model.reviewRequest(ref), let check = storedCheck else { return false }
        isWriting = true
        defer { isWriting = false }
        return await model.saveCheckScreenshot(request, check: check, key: key, png: png, viewport: viewport)
    }

    /// A comment on the check (allowed on someone else's request too).
    public func comment(_ text: String) async {
        guard let request = model.reviewRequest(ref), let check = storedCheck else { return }
        await model.comment(request, check: check, text: text)
    }
}
