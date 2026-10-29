public import Foundation

/// An activity in its original upload format (usually FIT), as recorded by the device.
public struct ActivityFile: Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    /// The activity the file belongs to.
    public let activityID: Int
    /// File name inside Garmin's archive, such as `12345_ACTIVITY.fit`.
    public let filename: String
    /// The file's bytes.
    public let content: Data

    /// An activity file.
    public init(activityID: Int, filename: String, content: Data) {
        self.activityID = activityID
        self.filename = filename
        self.content = content
    }

    /// Lower-case file extension without the dot, such as `"fit"`, `"gpx"` or `"tcx"`.
    public var fileExtension: String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else {
            return ""
        }
        return filename[filename.index(after: dot)...].lowercased()
    }

    /// The name and size, without the content.
    public var description: String {
        "ActivityFile(activityID: \(activityID), filename: \(filename), \(content.count) bytes)"
    }

    /// The name and size, without the content.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["activityID": activityID, "filename": filename, "size": content.count],
            displayStyle: .struct
        )
    }

    /// Write the file and return its URL.
    ///
    /// - Parameters:
    ///   - destination: A directory (the original file name is kept) or a file path.
    ///   - overwrite: Replace an existing file instead of throwing.
    /// - Throws: ``FileExistsError`` if the file exists and `overwrite` is false, or the
    ///   underlying file system error.
    /// - Returns: The URL of the written file.
    @discardableResult
    public func save(to destination: URL, overwrite: Bool = false) throws -> URL {
        var target = destination
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            target.appendPathComponent(filename)
        }
        if FileManager.default.fileExists(atPath: target.path), !overwrite {
            throw FileExistsError(target)
        }
        try PrivateFiles.write(content, to: target, permissions: nil)
        return target
    }

    /// Pick the activity file out of Garmin's download archive.
    ///
    /// - Throws: ``ZipArchive/Failure`` if the archive is unreadable, empty or holds an
    ///   oversized file.
    static func extract(
        activityID: Int, archive: Data, maxSize: Int = Constants.maxActivityFileSize
    ) throws(ZipArchive.Failure) -> Self {
        let zip = try ZipArchive([UInt8](archive))
        let files = zip.entries.filter { !$0.isDirectory }
        guard let first = files.first else {
            throw ZipArchive.Failure("the download archive is empty")
        }
        // Prefer the FIT file; Garmin archives normally contain exactly one file.
        let entry = files.first { $0.name.lowercased().hasSuffix(".fit") } ?? first
        guard entry.uncompressedSize <= maxSize else {
            throw ZipArchive.Failure(
                "\(entry.name) is implausibly large (\(entry.uncompressedSize) bytes)"
            )
        }
        // Only keep the base name; archive member names are untrusted paths.
        let base = entry.name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
        let name = base.flatMap { $0 == ".." || $0 == "." ? nil : $0 } ?? "\(activityID).fit"
        return Self(
            activityID: activityID, filename: name, content: Data(try zip.contents(of: entry)))
    }
}

/// A file that should not be replaced already exists.
public struct FileExistsError: GarminError {
    /// The existing file.
    public let url: URL

    init(_ url: URL) {
        self.url = url
    }

    /// What is wrong.
    public var message: String { "\(url.path) already exists; pass overwrite: true to replace it" }
}
