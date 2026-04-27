import Foundation
import AppKit
import ApplicationServices

struct WindowContext: Sendable, Codable {
    let bundleId: String
    let appName: String
    let windowTitle: String
    let documentPath: String?
    let pid: pid_t
    let timestamp: Date
}

enum WindowContextProbe {
    @MainActor
    static func current() -> WindowContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier
        else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focused: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused)

        var title = ""
        var docPath: String? = nil

        if let win = focused {
            // swift-format-ignore
            let winRef = win as! AXUIElement // AX values are CF, force-cast is correct here
            var rawTitle: AnyObject?
            AXUIElementCopyAttributeValue(winRef, kAXTitleAttribute as CFString, &rawTitle)
            if let t = rawTitle as? String { title = t }

            var rawDoc: AnyObject?
            AXUIElementCopyAttributeValue(winRef, kAXDocumentAttribute as CFString, &rawDoc)
            if let d = rawDoc as? String {
                if let url = URL(string: d), url.isFileURL {
                    docPath = url.path
                } else {
                    docPath = d
                }
            }
        }

        return WindowContext(
            bundleId: bundleId,
            appName: app.localizedName ?? bundleId,
            windowTitle: title,
            documentPath: docPath,
            pid: app.processIdentifier,
            timestamp: Date()
        )
    }

    @MainActor
    static func axTrustedPrompt() -> Bool {
        // The literal value of `kAXTrustedCheckOptionPrompt` is the documented
        // string "AXTrustedCheckOptionPrompt". Using it directly sidesteps
        // Swift 6's strict-concurrency complaint about referencing the C global.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts: NSDictionary = [key: true]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}
