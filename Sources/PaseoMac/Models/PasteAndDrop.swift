import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A pasted or dropped image that's ready to send with a message.
/// For MVP we only handle images (the original iOS-on-Mac blocker) and convert
/// them to PNG bytes with a small thumbnail for the composer UI.
struct PendingImageAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let pngData: Data
    let width: Int
    let height: Int
    let mimeType: String    // always "image/png" for now

    static func from(image: NSImage) -> PendingImageAttachment? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let w = Int(image.size.width.rounded())
        let h = Int(image.size.height.rounded())
        return PendingImageAttachment(
            id: UUID(),
            pngData: png,
            width: w,
            height: h,
            mimeType: "image/png"
        )
    }

    static func fromFileURL(_ url: URL) -> PendingImageAttachment? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return from(image: image)
    }

    /// Best-effort thumbnail suitable for an inline chip in the composer.
    func thumbnail(maxDim: CGFloat = 64) -> NSImage? {
        guard let src = NSImage(data: pngData) else { return nil }
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
