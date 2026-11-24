import AppKit
import ApplicationServices
import Carbon

@MainActor
struct PasteTarget {
    private let pid: pid_t
    private let element: AXUIElement
    let isSecure: Bool

    static func current() -> Self? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return Self(pid: pid, element: element, isSecure: (subrole as? String) == kAXSecureTextFieldSubrole)
    }

    func stillFocused() -> Bool {
        guard let focused = Self.current() else { return false }
        return focused.pid == pid && !focused.isSecure && CFEqual(focused.element, element)
    }

    enum Insertion { case inserted, typed, unavailable(String), unconfirmed }

    func insert(_ text: String, allowKeyboardInput: Bool) -> Insertion {
        guard stillFocused() else { return .unavailable("原輸入框焦點已變更") }
        guard !IsSecureEventInputEnabled() else { return .unavailable("macOS 正在使用安全鍵盤輸入") }
        // 這些編輯器可能回報 AX 寫入成功，但不更新草稿。
        switch NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
        case "com.openai.codex", "com.tinyspeck.slackmacgap":
            return typeText(text, allowed: allowKeyboardInput)
        default:
            break
        }
        let attribute = kAXSelectedTextAttribute as CFString
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        guard stillFocused() else { return .unavailable("原輸入框焦點已變更") }
        if status != .success || !settable.boolValue {
            switch status {
            case .success, .attributeUnsupported, .notImplemented, .noValue:
                return typeText(text, allowed: allowKeyboardInput)
            default:
                return .unavailable("無法讀取原輸入框狀態（\(status.rawValue)）")
            }
        }
        switch AXUIElementSetAttributeValue(element, attribute, text as CFString) {
        case .success: return .inserted
        case .cannotComplete: return .unconfirmed
        case .attributeUnsupported, .notImplemented:
            return typeText(text, allowed: allowKeyboardInput)
        default: return .unavailable("目標 App 拒絕直接輸入")
        }
    }

    private func typeText(_ text: String, allowed: Bool) -> Insertion {
        guard allowed else { return .unavailable("辨識期間有其他操作，已略過鍵盤輸入") }
        guard acceptsKeyboardText() else { return .unavailable("沒有辨識到可輸入的文字欄位") }
        guard !IsSecureEventInputEnabled() else { return .unavailable("macOS 正在使用安全鍵盤輸入") }
        guard !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return .unavailable("辨識文字含控制字元")
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else {
            return .unavailable("有修飾鍵仍按著")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false)
        else { return .unavailable("無法建立鍵盤事件") }
        guard stillFocused() else { return .unavailable("原輸入框焦點已變更") }
        down.flags = []
        up.flags = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            units.withUnsafeBufferPointer {
                down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
            }
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return .typed
    }

    private func acceptsKeyboardText() -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let role = value as? String else { return false }
        switch role {
        case kAXTextFieldRole, kAXTextAreaRole, "AXSearchField":
            return true
        case kAXWindowRole:
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "dev.herdr.app"
        default:
            return false
        }
    }
}
