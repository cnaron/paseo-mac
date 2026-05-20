import Foundation
import UniformTypeIdentifiers

/// A pasted or dropped image that's ready to send with a message.
public struct PendingImageAttachment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let width: Int
    public let height: Int
    public let mimeType: String

    public init(id: UUID, fileURL: URL, width: Int, height: Int, mimeType: String) {
        self.id = id
        self.fileURL = fileURL
        self.width = width
        self.height = height
        self.mimeType = mimeType
    }

    public var pngData: Data {
        (try? Data(contentsOf: fileURL)) ?? Data()
    }

    public static func cacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("PaseoMac/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func cleanOldCache(olderThan age: TimeInterval = 7 * 24 * 3600) {
        let dir = cacheDirectory()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for item in items {
            if let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
               created < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }
}

public struct PendingTextFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let content: String
    public let languageHint: String?

    public init(id: UUID, name: String, content: String, languageHint: String?) {
        self.id = id
        self.name = name
        self.content = content
        self.languageHint = languageHint
    }

    public static let maxInlineBytes = 256 * 1024

    public static func fromFileURL(_ url: URL) throws -> PendingTextFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maxInlineBytes {
            throw PendingTextFileError.tooLarge(actual: size, limit: maxInlineBytes)
        }
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw PendingTextFileError.binaryFile
        }
        let ext = url.pathExtension.lowercased()
        return PendingTextFile(id: UUID(), name: url.lastPathComponent, content: s,
                               languageHint: ext.isEmpty ? nil : ext)
    }
}

public enum PendingTextFileError: LocalizedError {
    case tooLarge(actual: Int, limit: Int)
    case binaryFile

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let a, let l): return "File too large (\(a / 1024) KB > \(l / 1024) KB)"
        case .binaryFile: return "Binary files are not supported; drop text only."
        }
    }
}

public struct PendingFileAttachment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let data: Data
    public let mimeType: String
    public let fileExtension: String

    public init(id: UUID, name: String, data: Data, mimeType: String, fileExtension: String) {
        self.id = id
        self.name = name
        self.data = data
        self.mimeType = mimeType
        self.fileExtension = fileExtension
    }

    public static let maxBytes = 10 * 1024 * 1024

    public static func fromFileURL(_ url: URL) throws -> PendingFileAttachment {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maxBytes {
            throw PendingFileError.tooLarge(actual: size, limit: maxBytes)
        }
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let mime = mimeTypeForExtension(ext)
        return PendingFileAttachment(id: UUID(), name: url.lastPathComponent, data: data,
                                     mimeType: mime, fileExtension: ext)
    }

    public var iconName: String {
        switch fileExtension {
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "rar", "7z": return "doc.zipper"
        case "mp3", "wav", "aac", "m4a", "flac": return "waveform"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx": return "tablecells"
        case "ppt", "pptx": return "rectangle.on.rectangle"
        default: return "doc"
        }
    }

    private static func mimeTypeForExtension(_ ext: String) -> String {
        switch ext {
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}

public enum PendingFileError: LocalizedError {
    case tooLarge(actual: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let a, let l):
            return "File too large (\(a / 1024 / 1024) MB > \(l / 1024 / 1024) MB)"
        }
    }
}
