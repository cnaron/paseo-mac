import AppKit
import Foundation
import UniformTypeIdentifiers
import PaseoUI

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
