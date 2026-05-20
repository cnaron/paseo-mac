import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - NSImage-based PendingImageAttachment helpers

extension PendingImageAttachment {
    private static let maxLongEdge: CGFloat = 1280
    private static let jpegQuality: CGFloat = 0.75

    static func from(image: NSImage) -> PendingImageAttachment? {
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
        let scale: CGFloat = longEdge > Int(maxLongEdge) ? maxLongEdge / CGFloat(longEdge) : 1.0
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
        if let jpeg = resizedRep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) {
            let fileURL = cacheDir.appendingPathComponent("\(id.uuidString).jpg")
            guard (try? jpeg.write(to: fileURL, options: .atomic)) != nil else { return nil }
            return PendingImageAttachment(id: id, fileURL: fileURL, width: dstW, height: dstH, mimeType: "image/jpeg")
        }
        guard let png = resizedRep.representation(using: .png, properties: [.interlaced: false]) else { return nil }
        let fileURL = cacheDir.appendingPathComponent("\(id.uuidString).png")
        guard (try? png.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return PendingImageAttachment(id: id, fileURL: fileURL, width: dstW, height: dstH, mimeType: "image/png")
    }

    static func fromFileURL(_ url: URL) -> PendingImageAttachment? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return from(image: image)
    }

    func thumbnail(maxDim: CGFloat = 64) -> NSImage? {
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
    }
}

// MARK: - PasteboardHelper

enum PasteboardHelper {
    static func extractImages(from pasteboard: NSPasteboard) -> [PendingImageAttachment] {
        var out: [PendingImageAttachment] = []
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            for img in images {
                if let att = PendingImageAttachment.from(image: img) { out.append(att) }
            }
        }
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
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }
}

// MARK: - MacPasteboard

struct MacPasteboard: PlatformPasteboard {
    func copyString(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
