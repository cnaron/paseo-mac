import AppKit
import Foundation

struct MacFileReveal: PlatformFileReveal {
    func revealFile(atPath path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
