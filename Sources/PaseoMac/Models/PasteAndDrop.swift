import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A pasted or dropped image that's ready to send with a message.
/// For MVP we only handle images (the original iOS-on-Mac blocker) and convert
/// them to PNG bytes with a small thumbnail for the composer UI.
struct PendingImageAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileURL: URL      // ~/Library/Caches/PaseoMac/images/<uuid>.png
    let width: Int
    let height: Int
    let mimeType: String  // always "image/png" for now

    var pngData: Data {
        (try? Data(contentsOf: fileURL)) ?? Data()
    }

    static func from(image: NSImage) -> PendingImageAttachment? {
        // Use the best available bitmap rep to get actual pixel dimensions,
        // not logical points — critical for Retina screenshots (2x/3x).
        let rep: NSBitmapImageRep?
        if let tiff = image.tiffRepresentation {
            rep = NSBitmapImageRep(data: tiff)
        } else {
            rep = image.representations
                .compactMap { $0 as? NSBitmapImageRep }
                .max(by: { $0.pixelsWide < $1.pixelsWide })
        }
        guard let bitmapRep = rep,
              let png = bitmapRep.representation(using: .png, properties: [.interlaced: false]) else {
            return nil
        }
        // pixelsWide/High = actual device pixels (2x on Retina)
        let w = bitmapRep.pixelsWide
        let h = bitmapRep.pixelsHigh
        let id = UUID()
        let fileURL = PendingImageAttachment.cacheDirectory().appendingPathComponent("\(id.uuidString).png")
        guard (try? png.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return PendingImageAttachment(
            id: id,
            fileURL: fileURL,
            width: max(w, 1),
            height: max(h, 1),
            mimeType: "image/png"
        )
    }

    static func fromFileURL(_ url: URL) -> PendingImageAttachment? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return from(image: image)
    }

    /// Best-effort thumbnail suitable for an inline chip in the composer.
    func thumbnail(maxDim: CGFloat = 64) -> NSImage? {
        guard let src = NSImage(contentsOf: fileURL) else { return nil }
        let ratio = CGFloat(width) / max(CGFloat(height), 1)
        let size: CGSize
        if ratio >= 1 {
            size = CGSize(width: maxDim, height: maxDim / ratio)
        } else {
            size = CGSize(width: maxDim * ratio, height: maxDim)
        }
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        src.draw(in: CGRect(origin: .zero, size: size))
        thumb.unlockFocus()
        return thumb
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

/// A text file dragged into the composer. The daemon protocol has no
/// first-class file slot, so we inline the content into the outgoing
/// message body as a fenced code block (matching Claude Code's behavior).
struct PendingTextFile: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let content: String
    /// Language hint for the fenced block, derived from the extension.
    let languageHint: String?

    /// Max bytes we'll inline. Larger → rejected with a size error.
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
        return PendingTextFile(
            id: UUID(),
            name: url.lastPathComponent,
            content: s,
            languageHint: ext.isEmpty ? nil : ext
        )
    }
}

enum PendingTextFileError: LocalizedError {
    case tooLarge(actual: Int, limit: Int)
    case binaryFile

    var errorDescription: String? {
        switch self {
        case .tooLarge(let a, let l):
            return "File too large (\(a / 1024) KB > \(l / 1024) KB)"
        case .binaryFile:
            return "Binary files are not supported; drop text only."
        }
    }
}

enum PasteboardHelper {
    /// Pulls all image-ish items out of the given pasteboard.
    /// Handles: raw image data (⌘V screenshots, copied from browsers),
    /// file URLs pointing at image files (copy from Finder).
    static func extractImages(from pasteboard: NSPasteboard) -> [PendingImageAttachment] {
        var out: [PendingImageAttachment] = []

        // 1) Direct NSImage payloads.
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            for img in images {
                if let att = PendingImageAttachment.from(image: img) {
                    out.append(att)
                }
            }
        }

        // 2) File URLs that happen to point at images. Deduped against #1 by
        // offset into the pasteboard — we don't try to perfectly unify.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls where url.isFileURL {
                if isImageType(url: url), let att = PendingImageAttachment.fromFileURL(url) {
                    out.append(att)
                }
            }
        }

        return out
    }

    private static func isImageType(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }
}


/// A generic file attachment (binary or otherwise) displayed as a chip with
/// icon + filename in the composer. Unlike PendingTextFile (which inlines
/// content as a code block), this type sends the file as a base64 attachment
/// through the daemon protocol.
struct PendingFileAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let data: Data
    let mimeType: String
    let fileExtension: String

    /// Max file size for upload: 10 MB
    static let maxBytes = 10 * 1024 * 1024

    static func fromFileURL(_ url: URL) throws -> PendingFileAttachment {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maxBytes {
            throw PendingFileError.tooLarge(actual: size, limit: maxBytes)
        }
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let mime = mimeTypeForExtension(ext)
        return PendingFileAttachment(
            id: UUID(),
            name: url.lastPathComponent,
            data: data,
            mimeType: mime,
            fileExtension: ext
        )
    }

    /// SF Symbol name based on file type
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
