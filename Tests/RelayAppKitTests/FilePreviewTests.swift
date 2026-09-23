import AppKit
import Foundation
import ImageIO
import RelayProtocol
import Testing
import UniformTypeIdentifiers

@testable import RelayAppKit

/// A real picture on a real disk, since what is under test is whether ImageIO
/// reads it the way the preview assumes.
private func writePNG(width: Int, height: Int, dotsPerInch: Double = 72, to url: URL) throws {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())

    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = [
        kCGImagePropertyDPIWidth: dotsPerInch,
        kCGImagePropertyDPIHeight: dotsPerInch,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

@Suite("What a file is shown as")
struct FilePreviewKindTests {
    @Test("Pictures, documents and recordings are previewed", arguments: [
        ("shot.png", FilePreview.Kind.image),
        ("PHOTO.JPG", .image),
        ("icon.icns", .image),
        ("paper.pdf", .pdf),
        ("demo.mov", .video),
        ("clip.webm", .video),
        ("voice.m4a", .audio),
    ])
    func previewed(name: String, kind: FilePreview.Kind) {
        #expect(FilePreview.Kind(path: "/p/\(name)") == kind)
    }

    @Test("Text stays with the editor", arguments: [
        // The system knows `.ts` and `.mts` as video containers. Asked, it
        // would open every TypeScript module in a player.
        "index.ts", "module.mts",
        // An image, and also a file people write by hand.
        "logo.svg",
        "README.md", "main.swift", "Makefile", ".env",
    ])
    func textIsNotPreviewed(name: String) {
        #expect(FilePreview.Kind(path: "/p/\(name)") == nil)
    }

    @Test("A preview needs the file to be there")
    @MainActor
    func missingFile() {
        #expect(FilePreview(path: "/definitely/not/here.png") == nil)
    }

    @Test("Only what can be zoomed takes a zoom")
    @MainActor
    func zoomRequests() throws {
        let directory = try TemporaryDirectory()
        try directory.write("", to: "voice.mp3")
        try writePNG(width: 4, height: 4, to: directory.url.appendingPathComponent("shot.png"))

        let recording = try #require(FilePreview(path: directory.url.appendingPathComponent("voice.mp3").path))
        recording.zoom(.zoomIn)
        #expect(recording.zoomRequest == nil)

        // Twice is two requests: a pane comparing only what was asked for
        // would take the second ⌘+ for nothing new.
        let picture = try #require(FilePreview(path: directory.url.appendingPathComponent("shot.png").path))
        picture.zoom(.zoomIn)
        let first = try #require(picture.zoomRequest)
        picture.zoom(.zoomIn)
        #expect(picture.zoomRequest != first)
        #expect(picture.zoomRequest?.zoom == .zoomIn)
    }
}

@Suite("Previews among the open files")
@MainActor
struct PreviewOpeningTests {
    @Test("A picture opens as a preview, not as a buffer")
    func opensAsPreview() throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.appendingPathComponent("shot.png").path
        try writePNG(width: 4, height: 4, to: URL(fileURLWithPath: path))

        let editors = FileEditors()
        #expect(editors.open(path))

        // Nothing that asks for text — the checker, find, ⌘S — is handed a
        // buffer of a picture's bytes.
        #expect(editors[path] == nil)
        #expect(editors.previews[path]?.kind == .image)
        #expect(editors.openPath == path)
        #expect(editors.open(path))
    }

    @Test("A WebP opens as a picture rather than failing as text")
    func webPOpens() throws {
        // What a web project's `public/images` is mostly made of, and what used
        // to end in "Could not open file": the bytes are not UTF-8, and text
        // was the only thing a pane could be. Carried as bytes because ImageIO
        // reads WebP but cannot write it — made with `cwebp -lossless` from a
        // 3 × 2 picture.
        let bytes = try #require(Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvAkAAAAdQniIXpf+BiOh/AAA="))
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("promo.webp")
        try bytes.write(to: url)

        let editors = FileEditors()
        #expect(editors.open(url.path))
        #expect(editors.previews[url.path]?.kind == .image)

        let decoded = try #require(PreviewImage.read(path: url.path))
        #expect(decoded.pixelWidth == 3)
        #expect(decoded.pixelHeight == 2)
        #expect(decoded.data.flatMap(NSImage.init(data:)) != nil)
    }

    @Test("A picture and a file take turns in the one pane")
    func oneAtATimeAcrossKinds() throws {
        let directory = try TemporaryDirectory()
        try directory.write("one\n", to: "notes.swift")
        let text = directory.url.appendingPathComponent("notes.swift").path
        let picture = directory.url.appendingPathComponent("shot.png").path
        try writePNG(width: 4, height: 4, to: URL(fileURLWithPath: picture))

        let editors = FileEditors()
        #expect(editors.open(text))
        try #require(editors[text]).text = "edited\n"

        #expect(editors.open(picture))
        #expect(editors.openPaths == [picture])
        // The buffer that gave way was written out on the way.
        #expect(try String(contentsOfFile: text, encoding: .utf8) == "edited\n")

        #expect(editors.open(text))
        #expect(editors.openPaths == [text])
        #expect(editors.previews.isEmpty)
    }

    @Test("⌘+ on a picture zooms it and leaves the text size alone")
    func fontKeysZoomAPicture() throws {
        let directory = try TemporaryDirectory()
        let picture = directory.url.appendingPathComponent("shot.png").path
        try writePNG(width: 4, height: 4, to: URL(fileURLWithPath: picture))
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)

        #expect(model.openFile(at: picture, in: project.id))
        let size = model.editorFontSize
        model.stepFontSize(by: 1)

        #expect(model.editorFontSize == size)
        #expect(model.editors.previews[picture]?.zoomRequest?.zoom == .zoomIn)

        model.resetFontSize()
        #expect(model.editors.previews[picture]?.zoomRequest?.zoom == .fit)
    }
}

@Suite("Reading a picture for its preview")
struct PreviewImageTests {
    @Test("A picture that fits is read whole, measured in pixels and in points")
    func readsWhole() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("retina.png")
        try writePNG(width: 8, height: 4, dotsPerInch: 144, to: url)

        let decoded = try #require(PreviewImage.read(path: url.path))
        #expect(decoded.data != nil)
        #expect(decoded.reduced == nil)
        #expect(decoded.pixelWidth == 8)
        #expect(decoded.pixelHeight == 4)
        // Taken on a Retina screen: half its pixels across, as NSImage has it.
        #expect(decoded.size == CGSize(width: 4, height: 2))
    }

    @Test("A picture too large to decode whole is read as a smaller copy")
    func readsReduced() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("poster.png")
        let side = 8200
        #expect(side * side > PreviewImage.largestDecodedPixels)
        try writePNG(width: side, height: side, to: url)

        let decoded = try #require(PreviewImage.read(path: url.path))
        let reduced = try #require(decoded.reduced)
        #expect(decoded.data == nil)
        #expect(max(reduced.width, reduced.height) <= PreviewImage.reducedSide)
        // Still reported at the size of the original.
        #expect(decoded.pixelWidth == side)
        #expect(decoded.size == CGSize(width: side, height: side))
    }

    @Test("A file named like a picture that is not one is refused")
    func refusesNonsense() throws {
        let directory = try TemporaryDirectory()
        try directory.write("not a picture", to: "fake.png")
        #expect(PreviewImage.read(path: directory.url.appendingPathComponent("fake.png").path) == nil)
    }
}

@Suite("Facts beside a preview's name")
struct PreviewFactsTests {
    @Test("A length is written the way a player writes it", arguments: [
        (7.0, "0:07"),
        (272.4, "4:32"),
        (3723.0, "1:02:03"),
    ])
    func duration(seconds: Double, written: String) {
        #expect(PreviewFacts.duration(seconds) == written)
    }

    @Test("A length that is not one is left out")
    func unknownDuration() {
        #expect(PreviewFacts.duration(.nan) == nil)
        #expect(PreviewFacts.joined([nil, "12 KB"]) == "12 KB")
        #expect(PreviewFacts.joined([PreviewFacts.dimensions(width: 1920, height: 1080), "1 MB"])
            == "1920 × 1080 · 1 MB")
    }
}
