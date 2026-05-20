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

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public extension PendingImageAttachment {
    static func from(image: PlatformImage) -> PendingImageAttachment? {
        #if os(macOS)
        let rep: NSBitmapImageRep?
        if let tiff = image.tiffRepresentation {
            rep = NSBitmapImageRep(data: tiff)
        } else {
            rep = image.representations.compactMap { $0 as? NSBitmapImageRep }
                .max(by: { $0.pixelsWide < $1.pixelsWide })
        }
        guard let bitmapRep = rep else { return nil }
        let srcW = bitmapRep.pixelsWide; let srcH = bitmapRep.pixelsHigh
        let longEdge = max(srcW, srcH)
        let scale: CGFloat = longEdge > 1280 ? 1280 / CGFloat(longEdge) : 1.0
        let dstW = max(Int(CGFloat(srcW) * scale), 1); let dstH = max(Int(CGFloat(srcH) * scale), 1)
        guard let cg = bitmapRep.cgImage else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: dstW, height: dstH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: dstW, height: dstH))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let resized = ctx.makeImage() else { return nil }
        let resizedRep = NSBitmapImageRep(cgImage: resized)
        let id = UUID()
        let cacheDir = PendingImageAttachment.cacheDirectory()
        if let jpeg = resizedRep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) {
            let fileURL = cacheDir.appendingPathComponent("\(id.uuidString).jpg")
            guard (try? jpeg.write(to: fileURL, options: .atomic)) != nil else { return nil }
            return PendingImageAttachment(id: id, fileURL: fileURL, width: dstW, height: dstH, mimeType: "image/jpeg")
        }
        guard let png = resizedRep.representation(using: .png, properties: [.interlaced: false]) else { return nil }
        let fileURL = cacheDir.appendingPathComponent("\(id.uuidString).png")
        guard (try? png.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return PendingImageAttachment(id: id, fileURL: fileURL, width: dstW, height: dstH, mimeType: "image/png")
        #else
        let srcW = Int(image.size.width * image.scale)
        let srcH = Int(image.size.height * image.scale)
        let maxEdge: CGFloat = 1280
        let longEdge = max(srcW, srcH)
        let scale: CGFloat = longEdge > Int(maxEdge) ? maxEdge / CGFloat(longEdge) : 1.0
        let dstW = max(Int(CGFloat(srcW) * scale), 1)
        let dstH = max(Int(CGFloat(srcH) * scale), 1)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: dstW, height: dstH))
        let resized = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: CGSize(width: dstW, height: dstH)))
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: dstW, height: dstH)))
        }

        let id = UUID()
        let cacheDir = PendingImageAttachment.cacheDirectory()
        guard let jpegData = resized.jpegData(compressionQuality: 0.75) else { return nil }
        let fileURL = cacheDir.appendingPathComponent("\(id.uuidString).jpg")
        guard (try? jpegData.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return PendingImageAttachment(id: id, fileURL: fileURL, width: dstW, height: dstH, mimeType: "image/jpeg")
        #endif
    }

    static func fromFileURL(_ url: URL) -> PendingImageAttachment? {
        #if os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return from(image: image)
        #else
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return from(image: image)
        #endif
    }

    func thumbnail(maxDim: CGFloat = 64) -> PlatformImage? {
        #if os(macOS)
        guard let src = NSImage(contentsOf: fileURL) else { return nil }
        let ratio = CGFloat(width) / max(CGFloat(height), 1)
        let size: CGSize = ratio >= 1
            ? CGSize(width: maxDim, height: maxDim / ratio)
            : CGSize(width: maxDim * ratio, height: maxDim)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        src.draw(in: CGRect(origin: .zero, size: size))
        thumb.unlockFocus()
        return thumb
        #else
        guard let src = UIImage(contentsOfFile: fileURL.path) else { return nil }
        let ratio = CGFloat(width) / max(CGFloat(height), 1)
        let size: CGSize = ratio >= 1
            ? CGSize(width: maxDim, height: maxDim / ratio)
            : CGSize(width: maxDim * ratio, height: maxDim)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        src.draw(in: CGRect(origin: .zero, size: size))
        let thumb = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return thumb
        #endif
    }
}
