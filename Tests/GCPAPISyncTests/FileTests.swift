import Foundation
import Testing

@testable import GCPAPISync

// Archives written by Python's zipfile: a fixed-Huffman, a dynamic-Huffman and a
// stored-block deflate stream.
private let fixedHuffman =
    "UEsDBBQAAAAIAEViXV1LC0xQBQAAAAMAAAAOAAAANV9BQ1RJVklUWS5maXRLyywBAFBLAQIUAxQAAAAI"
    + "AEViXV1LC0xQBQAAAAMAAAAOAAAAAAAAAAAAAACAAQAAAAA1X0FDVElWSVRZLmZpdFBLBQYAAAAAAQAB"
    + "ADwAAAAxAAAAAAA="
private let dynamicHuffman =
    "UEsDBBQAAAAIAEViXV3mRl6TWAAAALgkAAAOAAAAMV9BQ1RJVklUWS5maXTtyTkOgkAAAMCv7Fc4ZEHl"
    + "FC+6TWgspDD+P3xDkyknE9Pn/dpC1cxhTd8UIjMzMzMzMzMzMzMz8587q/tbcRwfh/Nlid01b4Z7eZqe"
    + "VTsbY4wxxhhjfmV2UEsBAhQDFAAAAAgARWJdXeZGXpNYAAAAuCQAAA4AAAAAAAAAAAAAAIABAAAAADFf"
    + "QUNUSVZJVFkuZml0UEsFBgAAAAABAAEAPAAAAIQAAAAAAA=="
private let storedBlock =
    "UEsDBBQAAAAIAEViXV3fZaClFgAAABEAAAAOAAAAMl9BQ1RJVklUWS5maXQBEQDu/3N0b3JlZCBibG9j"
    + "ayBkYXRhUEsBAhQDFAAAAAgARWJdXd9loKUWAAAAEQAAAA4AAAAAAAAAAAAAAIABAAAAADJfQUNUSVZJ"
    + "VFkuZml0UEsFBgAAAAABAAEAPAAAAEIAAAAAAA=="

private func base64(_ text: String) throws -> Data {
    try #require(Data(base64Encoded: text))
}

@Suite struct ArchiveTests {
    @Test func extractsTheOnlyFile() throws {
        let result = try ActivityFile.extract(
            activityID: 1, archive: zipArchive([("1_ACTIVITY.gpx", Data("<gpx/>".utf8))]))
        #expect(
            result
                == ActivityFile(
                    activityID: 1, filename: "1_ACTIVITY.gpx", content: Data("<gpx/>".utf8)))
        #expect(result.fileExtension == "gpx")
        #expect(!"\(result)".contains("gpx/>"))
        var dumped = ""
        dump(result, to: &dumped)
        #expect(dumped.contains("size: 6"))
    }

    @Test func prefersTheFITFile() throws {
        let archive = zipArchive([
            ("notes.txt", Data("x".utf8)), ("nested/", Data()),
            ("nested/1_ACTIVITY.FIT", Data("fit".utf8)),
        ])
        let result = try ActivityFile.extract(activityID: 1, archive: archive)
        #expect(result.filename == "1_ACTIVITY.FIT")
        #expect(result.fileExtension == "fit")
    }

    @Test(arguments: ["../../etc/evil.fit", "/abs/evil.fit", "..\\..\\evil.fit"])
    func memberPathsAreReducedToBaseNames(name: String) throws {
        #expect(
            try ActivityFile.extract(activityID: 1, archive: zipArchive([(name, Data("x".utf8))]))
                .filename == "evil.fit")
    }

    @Test(arguments: ["..", "a/.."])
    func dotNamesFallBackToTheActivityID(name: String) throws {
        #expect(
            try ActivityFile.extract(activityID: 9, archive: zipArchive([(name, Data("x".utf8))]))
                .filename == "9.fit")
    }

    @Test func fileExtensions() {
        #expect(
            ActivityFile(activityID: 1, filename: "noext", content: Data()).fileExtension.isEmpty)
        #expect(
            ActivityFile(activityID: 1, filename: ".hidden", content: Data()).fileExtension.isEmpty)
        #expect(
            ActivityFile(activityID: 1, filename: "a.TCX", content: Data()).fileExtension == "tcx")
    }

    @Test(arguments: [("not a zip", "not a zip"), ("", "not a zip")])
    func invalidArchives(content: String, message: String) {
        let error = #expect(throws: ZipArchive.Failure.self) {
            try ActivityFile.extract(activityID: 1, archive: Data(content.utf8))
        }
        #expect(error?.message.contains(message) == true)
    }

    @Test func emptyArchives() {
        let error = #expect(throws: ZipArchive.Failure.self) {
            try ActivityFile.extract(activityID: 1, archive: zipArchive([]))
        }
        #expect(error?.message.contains("empty") == true)
    }

    @Test func oversizedMembersAreRefused() {
        let error = #expect(throws: ZipArchive.Failure.self) {
            try ActivityFile.extract(
                activityID: 1, archive: zipArchive([("1.fit", Data("1234".utf8))]), maxSize: 3)
        }
        #expect(error?.message.contains("implausibly large") == true)
    }

    @Test func corruptMembersAreRefused() {
        var archive = [UInt8](zipArchive([("1.fit", Data("1234".utf8))]))
        archive[35] ^= 0xff  // flip a content byte: the CRC no longer matches
        let error = #expect(throws: ZipArchive.Failure.self) {
            try ActivityFile.extract(activityID: 1, archive: Data(archive))
        }
        #expect(error?.message.contains("corrupt") == true)
    }

    @Test func truncatedArchivesAreRefused() {
        let archive = [UInt8](zipArchive([("1.fit", Data("1234".utf8))]))
        // Point the central directory's local-header offset past the end.
        var badOffset = archive
        let central = archive.count - 22 - 51
        badOffset[central + 42] = 0xff
        #expect(throws: ZipArchive.Failure.self) {
            try ActivityFile.extract(activityID: 1, archive: Data(badOffset))
        }
        var badDirectory = archive
        badDirectory[central] = 0
        #expect(throws: ZipArchive.Failure.self) {
            try ActivityFile.extract(activityID: 1, archive: Data(badDirectory))
        }
        var badMethod = archive
        badMethod[central + 10] = 9
        let error = #expect(throws: ZipArchive.Failure.self) {
            try ActivityFile.extract(activityID: 1, archive: Data(badMethod))
        }
        #expect(error?.message.contains("unsupported compression") == true)
        var badSize = archive
        badSize[central + 20] = 0xff
        #expect(throws: ZipArchive.Failure.self) {
            try ActivityFile.extract(activityID: 1, archive: Data(badSize))
        }
    }

    @Test func inflatesFixedHuffmanBlocks() throws {
        let file = try ActivityFile.extract(activityID: 5, archive: try base64(fixedHuffman))
        #expect(file.content == Data("fit".utf8))
    }

    @Test func inflatesDynamicHuffmanBlocks() throws {
        let expected =
            String(repeating: "Garmin FIT data ", count: 400)
            + String((0..<3000).map { Character(Unicode.Scalar(UInt8(65 + $0 * 7 % 26))) })
        let file = try ActivityFile.extract(activityID: 1, archive: try base64(dynamicHuffman))
        #expect(file.content == Data(expected.utf8))
    }

    @Test func inflatesStoredBlocks() throws {
        let file = try ActivityFile.extract(activityID: 2, archive: try base64(storedBlock))
        #expect(file.content == Data("stored block data".utf8))
    }

    @Test func inflateRejectsBrokenStreams() throws {
        let streams: [[UInt8]] = [
            [],  // ends before the first block
            [0x07],  // reserved block type 3
            [0x01, 0x05, 0x00, 0x00, 0x00],  // stored block with a bad length complement
            [0x01, 0x05, 0x00],  // stored block header cut short
            [0x01, 0x05, 0x00, 0xfa, 0xff, 0x61],  // stored block shorter than its length
            [0x63, 0x00],  // fixed block: a distance before any output
            [0x05, 0xe0, 0xff, 0xff, 0xff, 0xff],  // dynamic block with impossible code lengths
        ]
        for stream in streams {
            #expect(throws: ZipArchive.Failure.self) { try Inflate.decompress(stream, limit: 100) }
        }
        // zlib's raw deflate of 1000 "a"s: far more than the declared size.
        let bomb: [UInt8] = [75, 76, 28, 5, 163, 96, 20, 12, 119, 0, 0]
        #expect(try Inflate.decompress(bomb, limit: 1000) == [UInt8](repeating: 97, count: 1000))
        let error = #expect(throws: ZipArchive.Failure.self) {
            try Inflate.decompress(bomb, limit: 2)
        }
        #expect(error?.message == "data is too large")
    }

    @Test func saveIntoDirectoryAndToPath() throws {
        let scratch = try Scratch()
        let directory = scratch.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let activity = ActivityFile(
            activityID: 1, filename: "1_ACTIVITY.fit", content: Data("data".utf8))

        let saved = try activity.save(to: directory)
        #expect(saved == directory.appendingPathComponent("1_ACTIVITY.fit"))
        #expect(try Data(contentsOf: saved) == Data("data".utf8))
        let exists = #expect(throws: FileExistsError.self) { try activity.save(to: directory) }
        #expect(exists?.message.contains("already exists") == true)
        try ActivityFile(activityID: 1, filename: "1_ACTIVITY.fit", content: Data("new".utf8))
            .save(to: directory, overwrite: true)
        #expect(try Data(contentsOf: saved) == Data("new".utf8))

        let custom = try activity.save(to: directory.appendingPathComponent("sub/run.fit"))
        #expect(try Data(contentsOf: custom) == Data("data".utf8))
        let names = try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["1_ACTIVITY.fit", "sub", "sub/run.fit"])
    }

    @Test func saveCleansUpAfterFailures() throws {
        let scratch = try Scratch()
        let target = scratch.url.appendingPathComponent("a.fit")
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("child"), withIntermediateDirectories: true)
        // The target is a directory, so the file lands inside it.
        let saved = try ActivityFile(activityID: 1, filename: "a.fit", content: Data("x".utf8))
            .save(to: target, overwrite: true)
        #expect(saved == target.appendingPathComponent("a.fit"))
        let blocked = scratch.url.appendingPathComponent("b.fit")
        try FileManager.default.createDirectory(
            at: blocked.appendingPathComponent("b.fit/child"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try ActivityFile(activityID: 1, filename: "b.fit", content: Data("x".utf8))
                .save(to: blocked, overwrite: true)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: blocked.path) == ["b.fit"])
    }
}

@Suite struct ChecksumTests {
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            String(repeating: "a", count: 1000),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
        ),
    ])
    func sha256(message: String, digest: String) {
        #expect(SHA256.hex(Array(message.utf8)) == digest)
    }

    @Test func crc32() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xcbf4_3926)
        #expect(CRC32.checksum([]) == 0)
    }
}
