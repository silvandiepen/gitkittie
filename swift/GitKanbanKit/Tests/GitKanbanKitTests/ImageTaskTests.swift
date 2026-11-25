import CoreGraphics
import GitKittieKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GitKanbanKit

/// Making a task from images — what a drop on the Mac board and the iPhone's share sheet
/// both do — end to end over a real folder board: the lane it lands in, the card file,
/// and the image in the card's attachments folder.
@MainActor
final class ImageTaskTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-image-task-\(UUID().uuidString)", isDirectory: true)
        suite = "gk-image-task-tests-\(UUID().uuidString)"
        // A backlog lane first: a drop off the lanes still lands in To do, not the backlog.
        try write("Tasks/README.md", """
        ---
        config: board
        lanes:
          - id: backlog
            name: Backlog
            folder: "0. Backlog"
            status: backlog
            backlog: true
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
          - id: in-progress
            name: In Progress
            folder: "2. In Progress"
            status: in-progress
          - id: done
            name: Done
            folder: "5. Done"
            status: done
            terminal: true
        ---
        """)
        try write("Tasks/Morrow/README.md", "---\nconfig: project\nproject: Morrow\nlanes: []\n---\n")
        try write("Tasks/Morrow/1. To do/MORROW-001-fix-the-door.md", CardText.make(
            id: "MORROW-001", title: "Fix the door", project: "Morrow", status: "todo"))
        for folder in ["0. Backlog", "2. In Progress", "5. Done"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Morrow/\(folder)"), withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        AppModel.removeTestStorage(suite)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func openBoard() async throws -> AppModel {
        let app = AppModel.testing(suite: suite, keychainService: "gk-image-task-tests")
        let repo = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                             boards: [SelectedBoard(folder: "Tasks/Morrow", name: "Morrow")],
                             kind: .localFolder(path: root.path, bookmark: nil))
        app.addedRepos = [repo]
        await app.openBoard(repo, folder: "Tasks/Morrow")
        app.stopWatching()
        XCTAssertNil(app.errorMessage)
        XCTAssertNotNil(app.board)
        return app
    }

    /// A white image of the given size, encoded as `type`.
    private func image(width: Int = 200, height: Int = 100, as type: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(TaskImage.encode(try XCTUnwrap(context.makeImage()), as: type))
    }

    private func stamp(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: text)!
    }

    // MARK: Where it lands

    func testDropOnALaneGoesToThatLaneAndElsewhereToToDo() async throws {
        let app = try await openBoard()
        XCTAssertEqual(app.laneForDroppedImages(onLaneID: "in-progress")?.id, "in-progress")
        XCTAssertEqual(app.laneForDroppedImages(onLaneID: "backlog")?.id, "backlog", "a drop on the backlog lane is meant")
        XCTAssertEqual(app.laneForDroppedImages(onLaneID: nil)?.id, "todo")
        // The "Uncategorised" column is not a lane: a drop there goes to To do.
        XCTAssertEqual(app.laneForDroppedImages(onLaneID: "_uncategorised")?.id, "todo")
    }

    /// A drop opens the new-task sheet in the lane, holding the images, which it takes once.
    func testADropStartsANewTaskInTheLaneWithTheImages() async throws {
        let app = try await openBoard()
        let shot = try XCTUnwrap(TaskImage.from(try image()))
        XCTAssertTrue(app.startTask(fromImages: [shot], onLaneID: "in-progress"))
        XCTAssertEqual(app.newTaskLane?.id, "in-progress")
        XCTAssertEqual(app.takeNewTaskImages().map(\.id), [shot.id])
        XCTAssertTrue(app.newTaskImages.isEmpty)

        app.newTaskLane = nil
        XCTAssertTrue(app.startTask(fromImages: [shot], onLaneID: nil))
        XCTAssertEqual(app.newTaskLane?.id, "todo")

        app.newTaskLane = nil
        XCTAssertFalse(app.startTask(fromImages: [], onLaneID: "todo"), "a drop with no image in it starts nothing")
        XCTAssertNil(app.newTaskLane)
        XCTAssertNotNil(app.errorMessage)
    }

    func testDroppedScreenshotBecomesACardInTheLaneWithTheImageAttached() async throws {
        let app = try await openBoard()
        let png = try image()
        let shot = try XCTUnwrap(TaskImage.from(png))
        XCTAssertEqual(shot.fileExtension, "png")
        let lane = try XCTUnwrap(app.laneForDroppedImages(onLaneID: "in-progress"))

        let result = await app.createTask(fromImages: [shot], title: "Login button is cut off", lane: lane,
                                          notes: "Seen on the sign-in screen.", at: stamp("20261125-101500"))
        let made = try XCTUnwrap(result)
        XCTAssertEqual(made.cardID, "MORROW-002")
        XCTAssertEqual(made.attached, ["screenshot-20261125-101500.png"])
        XCTAssertEqual(made.failed, 0)

        let card = try String(contentsOf: root.appendingPathComponent(
            "Tasks/Morrow/2. In Progress/MORROW-002-login-button-is-cut-off.md"), encoding: .utf8)
        XCTAssertTrue(card.contains("status: in-progress"))
        XCTAssertTrue(card.contains("Seen on the sign-in screen."))
        // Unmarked and small: the file is the dropped image, byte for byte.
        let stored = root.appendingPathComponent("Tasks/Morrow/attachments/MORROW-002/screenshot-20261125-101500.png")
        XCTAssertEqual(try Data(contentsOf: stored), png)
        XCTAssertTrue(app.attachmentCardIDs.contains("MORROW-002"), "the card shows its paperclip at once")
        let card002 = try XCTUnwrap(app.allCards.first { $0.fields.id == "MORROW-002" })
        let listed = await app.attachments(for: card002)
        XCTAssertEqual(listed.map(\.name), ["screenshot-20261125-101500.png"])
    }

    func testSeveralImagesWithMarksMakeOneCardWithNumberedFilesAndTheMarksListed() async throws {
        let app = try await openBoard()
        var first = try XCTUnwrap(TaskImage.from(try image()))
        first.annotations = [ImageAnnotation(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), comment: "Save does nothing")]
        let second = try XCTUnwrap(TaskImage.from(try image(as: .jpeg)))
        XCTAssertEqual(second.fileExtension, "jpg")
        let lane = try XCTUnwrap(app.laneForDroppedImages(onLaneID: nil))

        // No title typed: the first comment on a mark is the title.
        let result = await app.createTask(fromImages: [first, second], title: "  ", lane: lane,
                                          at: stamp("20261125-101500"))
        let made = try XCTUnwrap(result)
        XCTAssertEqual(made.attached, ["screenshot-20261125-101500-1.png", "screenshot-20261125-101500-2.jpg"])
        let card = try String(contentsOf: root.appendingPathComponent(
            "Tasks/Morrow/1. To do/MORROW-002-save-does-nothing.md"), encoding: .utf8)
        XCTAssertNotNil(card.range(of: #"\ntitle: "?Save does nothing"?\n"#, options: .regularExpression), card)
        XCTAssertTrue(card.contains("## Annotations\n\nScreenshot 1:\n1. Save does nothing"))
        // The marked image is stored with the mark drawn on it, so it is not the original.
        let marked = try Data(contentsOf: root.appendingPathComponent("Tasks/Morrow/attachments/MORROW-002/screenshot-20261125-101500-1.png"))
        XCTAssertNotEqual(marked, first.data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "Tasks/Morrow/attachments/MORROW-002/screenshot-20261125-101500-2.jpg").path))
    }

    func testNoTitleAndNoMarksIsTitledScreenshotAndTheTime() {
        let images = [TaskImage(data: Data([1]), fileExtension: "png")]
        let date = stamp("20261125-101500")
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        XCTAssertEqual(AppModel.imageTaskTitle(images, at: date), "Screenshot \(formatter.string(from: date))")
    }

    // MARK: Reading what was dropped

    func testLoadsAScreenshotFileFromADropAndSkipsWhatIsNotAnImage() async throws {
        let png = try image()
        let file = root.appendingPathComponent("Screenshot 2026-11-25 at 10.15.00.png")
        try png.write(to: file)
        let text = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)

        // What Finder, the desktop and the screenshot thumbnail put on the drag: a file URL.
        let providers = [NSItemProvider(object: file as NSURL), NSItemProvider(object: text as NSURL)]
        XCTAssertTrue(TaskImage.canLoad(from: providers))
        let images = await TaskImage.load(from: providers)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.fileExtension, "png")
        XCTAssertEqual(images.first?.data, png)
    }

    func testImageDataFromAnotherAppIsKeptAsPNGOrMadeJPEG() async throws {
        let png = try image()
        let tiff = try image(as: .tiff)
        let pngProvider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let tiffProvider = NSItemProvider(item: tiff as NSData, typeIdentifier: UTType.tiff.identifier)
        let images = await TaskImage.load(from: [pngProvider, tiffProvider])
        XCTAssertEqual(images.map(\.fileExtension), ["png", "jpg"])
        XCTAssertEqual(images.first?.data, png)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(images[1].data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(images[1].pixelSize, CGSize(width: 200, height: 100))
    }

    /// Some apps share an image without saying it is one: as bytes typed only `public.data`,
    /// or as a file whose name has no image extension (registered as a `dyn.` type). The
    /// share sheet offers Tasks for those, so they have to load; what is not an image is
    /// still skipped.
    func testImageBytesOfNoStatedTypeLoadAndOtherBytesDoNot() async throws {
        let png = try image()
        let jpeg = try image(as: .jpeg)
        let file = root.appendingPathComponent("file-7a1c2e")
        try png.write(to: file)
        let notAnImage = root.appendingPathComponent("export-31f0")
        try Data("not an image".utf8).write(to: notAnImage)

        let untypedPNG = NSItemProvider(item: png as NSData, typeIdentifier: UTType.data.identifier)
        let dynamicJPEG = NSItemProvider(item: jpeg as NSData, typeIdentifier: "dyn.age8u")
        let fileWithoutExtension = NSItemProvider(object: file as NSURL)
        let untypedText = NSItemProvider(item: Data("hello".utf8) as NSData, typeIdentifier: UTType.data.identifier)
        let fileThatIsNotAnImage = NSItemProvider(object: notAnImage as NSURL)

        let providers = [untypedPNG, dynamicJPEG, fileWithoutExtension, untypedText, fileThatIsNotAnImage]
        XCTAssertTrue(TaskImage.canLoad(from: [untypedPNG]))
        let images = await TaskImage.load(from: providers)
        XCTAssertEqual(images.map(\.fileExtension), ["png", "jpg", "png"])
        XCTAssertEqual(images.first?.data, png)
        XCTAssertEqual(images.last?.data, png)
    }

    func testOnlyPublicDataAndDynamicTypesCountAsUntyped() {
        XCTAssertTrue(TaskImage.isUntyped("public.data"))
        XCTAssertTrue(TaskImage.isUntyped("dyn.age8u"))
        for described in ["public.png", "public.plain-text", "public.url", "public.file-url", "com.adobe.pdf", "public.zip-archive"] {
            XCTAssertFalse(TaskImage.isUntyped(described), described)
        }
    }

    func testPlainTextIsNotAnImageDrop() {
        XCTAssertFalse(TaskImage.canLoad(from: [NSItemProvider(object: "MORROW-001" as NSString)]))
    }

    // MARK: The marks in the file

    /// The box is drawn where it was marked: near the top of the image, not mirrored to
    /// the bottom (Core Graphics counts from the bottom; marks from the top).
    func testMarksAreDrawnUprightWhereTheyWereMade() throws {
        var shot = try XCTUnwrap(TaskImage.from(try image(width: 400, height: 400)))
        shot.annotations = [ImageAnnotation(rect: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.2), comment: "")]
        let file = shot.attachment()
        XCTAssertEqual(file.fileExtension, "png")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(file.data as CFData, nil))
        let drawn = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(drawn.width, 400)

        // Read the pixels back, top row first.
        var pixels = [UInt8](repeating: 0, count: 400 * 400 * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 400 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: 400, height: 400))
        func isRed(x: Int, y: Int) -> Bool {
            let i = (y * 400 + x) * 4
            return pixels[i] > 180 && pixels[i + 1] < 120 && pixels[i + 2] < 120
        }
        // The box's bottom edge runs along y = 0.3 × 400 = 120 from the top, at mid-width.
        XCTAssertTrue(isRed(x: 200, y: 120), "the box's lower edge is where it was marked")
        XCTAssertFalse(isRed(x: 200, y: 280), "and not mirrored to the bottom half")
        XCTAssertFalse(isRed(x: 200, y: 80), "inside the box the image is untouched")
    }
}
