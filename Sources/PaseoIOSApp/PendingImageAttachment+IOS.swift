import UIKit
import PaseoUI

extension PendingImageAttachment {
    static func from(image: UIImage) -> PendingImageAttachment? {
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
    }
}
