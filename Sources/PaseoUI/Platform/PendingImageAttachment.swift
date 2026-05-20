import Foundation
import UniformTypeIdentifiers

/// A pasted or dropped image that's ready to send with a message.
struct PendingImageAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileURL: URL
    let width: Int
    let height: Int
    let mimeType: String

    var pngData: Data {
        (try? Data(contentsOf: fileURL)) ?? Data()
    }

    static func cacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("PaseoMac/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanOldCache(olderThan age: TimeInterval = 7 * 24 * 3600) {
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

struct PendingTextFile: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let content: String
    let languageHint: String?

    static let maxInlineBytes = 256 * 1024

    static func fromFileURL(_ url: URL) throws -> PendingTextFile {
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

enum PendingTextFileError: LocalizedError {
    case tooLarge(actual: Int, limit: Int)
    case binaryFile

    var errorDescription: String? {
        switch self {
        case .tooLarge(let a, let l): return "File too large (\(a / 1024) KB > \(l / 1024) KB)"
        case .binaryFile: return "Binary files are not supported; drop text only."
        }
    }
}

struct PendingFileAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let data: Data
    let mimeType: String
    let fileExtension: String

    static let maxBytes = 10 * 1024 * 1024

    static func fromFileURL(_ url: URL) throws -> PendingFileAttachment {
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

    var iconName: String {
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

enum PendingFileError: LocalizedError {
    case tooLarge(actual: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let a, let l):
            return "File too large (\(a / 1024 / 1024) MB > \(l / 1024 / 1024) MB)"
        }
    }
}
