// SPDX-License-Identifier: BUSL-1.1

import AppKit
import ApplicationServices
import Foundation

struct AccessibilityTextResult: Sendable, Equatable {
  let text: String
  let nodesVisited: Int
  let truncated: Bool
}

enum AccessibilityTextExtractor {
  @MainActor
  static func current(
    context: WindowContext?,
    maxChars: Int = 8192,
    maxNodes: Int = 160,
    maxDepth: Int = 6
  ) -> AccessibilityTextResult? {
    guard AXIsProcessTrusted(), maxChars > 0, maxNodes > 0, maxDepth >= 0 else { return nil }
    let pid: pid_t
    if let context {
      pid = context.pid
    } else if let app = NSWorkspace.shared.frontmostApplication {
      pid = app.processIdentifier
    } else {
      return nil
    }

    let appElement = AXUIElementCreateApplication(pid)
    guard let focused = copyElement(appElement, attribute: kAXFocusedWindowAttribute) else {
      return nil
    }

    return extract(
      root: focused,
      maxChars: maxChars,
      maxNodes: maxNodes,
      maxDepth: maxDepth
    )
  }

  static func extract(
    root: AXUIElement,
    maxChars: Int = 8192,
    maxNodes: Int = 160,
    maxDepth: Int = 6
  ) -> AccessibilityTextResult {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var textParts: [String] = []
    var seenText = Set<String>()
    var nodesVisited = 0
    var remainingChars = max(0, maxChars)
    var truncated = false

    while let (element, depth) = stack.popLast(), nodesVisited < maxNodes, remainingChars > 0 {
      nodesVisited += 1
      for value in textValues(element) {
        let normalized = normalize(value)
        guard !normalized.isEmpty, seenText.insert(normalized).inserted else { continue }
        if normalized.count > remainingChars {
          textParts.append(String(normalized.prefix(remainingChars)))
          remainingChars = 0
          truncated = true
          break
        }
        textParts.append(normalized)
        remainingChars -= normalized.count
      }

      guard depth < maxDepth, remainingChars > 0 else { continue }
      var children = childElements(element, attribute: kAXChildrenAttribute)
      children += childElements(element, attribute: kAXVisibleChildrenAttribute)
      for child in children.reversed() {
        stack.append((child, depth + 1))
      }
    }

    if nodesVisited >= maxNodes, !stack.isEmpty {
      truncated = true
    }

    let text = normalize(textParts.joined(separator: "\n"))
    guard !text.isEmpty else {
      return AccessibilityTextResult(text: "", nodesVisited: nodesVisited, truncated: truncated)
    }
    return AccessibilityTextResult(text: text, nodesVisited: nodesVisited, truncated: truncated)
  }

  static func normalize(_ value: String) -> String {
    value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func textValues(_ element: AXUIElement) -> [String] {
    [
      kAXSelectedTextAttribute,
      kAXValueAttribute,
      kAXTitleAttribute,
      kAXDescriptionAttribute,
      kAXHelpAttribute,
    ]
    .compactMap { copyString(element, attribute: $0) }
  }

  private static func childElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
      let raw
    else {
      return []
    }
    if CFGetTypeID(raw) == AXUIElementGetTypeID() {
      // swift-format-ignore
      return [raw as! AXUIElement]
    }
    guard let array = raw as? [AnyObject] else { return [] }
    return array.compactMap { value in
      guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
      // swift-format-ignore
      return (value as! AXUIElement)
    }
  }

  private static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
      let raw,
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else {
      return nil
    }
    // swift-format-ignore
    return (raw as! AXUIElement)
  }

  private static func copyString(_ element: AXUIElement, attribute: String) -> String? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
      let raw
    else {
      return nil
    }
    if let value = raw as? String {
      return value
    }
    if let value = raw as? NSAttributedString {
      return value.string
    }
    if let value = raw as? URL {
      return value.absoluteString
    }
    return nil
  }
}
