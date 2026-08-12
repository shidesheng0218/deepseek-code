#if os(macOS)
import ApplicationServices
import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import Foundation

public struct ComputerToolHost: ToolHost {
    public let allowedBundleIdentifier: String?

    public init(allowedBundleIdentifier: String? = nil) {
        self.allowedBundleIdentifier = allowedBundleIdentifier
    }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        guard AXIsProcessTrusted() else {
            throw UnifiedRuntimeError.remote("未获得 macOS 辅助功能权限，请在系统设置中允许 DeepSeek Code")
        }
        let arguments = try decode(argumentsJSON)
        let application = try targetApplication(arguments: arguments)
        let root = AXUIElementCreateApplication(application.processIdentifier)

        switch tool.name {
        case "computer.inspect_app":
            return json([
                "ok": true,
                "application": application.localizedName ?? "",
                "bundleID": application.bundleIdentifier ?? "",
                "pid": application.processIdentifier,
                "accessibilityTrusted": true
            ])
        case "computer.snapshot":
            return json([
                "ok": true,
                "application": application.localizedName ?? "",
                "bundleID": application.bundleIdentifier ?? "",
                "tree": accessibilityTree(root, depth: 0, limit: 160)
            ])
        case "computer.find":
            let matches = find(root, title: arguments["title"] as? String, role: arguments["role"] as? String, limit: 20)
            return json(["ok": true, "matches": matches])
        case "computer.click":
            let element = try findOne(root, title: arguments["title"] as? String, role: arguments["role"] as? String)
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(element, kAXSubroleAttribute) as? String
            guard role != kAXTextFieldRole && subrole != kAXSecureTextFieldSubrole else {
                throw UnifiedRuntimeError.remote("禁止操作安全输入控件")
            }
            let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
            guard status == .success else { throw UnifiedRuntimeError.remote("点击失败：\(status.rawValue)") }
            return json(["ok": true, "action": "click", "role": role])
        case "computer.type":
            let element = try findOne(root, title: arguments["title"] as? String, role: kAXTextFieldRole)
            let subrole = attribute(element, kAXSubroleAttribute) as? String
            guard subrole != kAXSecureTextFieldSubrole else {
                throw UnifiedRuntimeError.remote("禁止向安全输入控件输入文本")
            }
            guard let text = arguments["text"] as? String, !text.contains("\u{0}") else {
                throw UnifiedRuntimeError.invalidArguments
            }
            let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
            guard status == .success else { throw UnifiedRuntimeError.remote("输入失败：\(status.rawValue)") }
            return json(["ok": true, "action": "type", "characterCount": text.count])
        case "computer.key":
            let key = arguments["key"] as? String ?? ""
            try postKey(key)
            return json(["ok": true, "action": "key", "key": key])
        case "computer.capture_window":
            let path = try await captureWindow(application: application)
            return json(["ok": true, "path": path, "application": application.localizedName ?? ""])
        default:
            throw UnifiedRuntimeError.toolHostUnavailable(tool.name)
        }
    }

    public func cancel(invocationID: String) async {}

    private func targetApplication(arguments: [String: Any]) throws -> NSRunningApplication {
        let requestedBundleID = arguments["bundleID"] as? String ?? allowedBundleIdentifier
        if let requestedBundleID,
           let application = NSRunningApplication.runningApplications(withBundleIdentifier: requestedBundleID).first {
            return application
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.activationPolicy == .regular {
            if let allowedBundleIdentifier, frontmost.bundleIdentifier != allowedBundleIdentifier {
                throw UnifiedRuntimeError.remote("当前前台应用不在本 Session 允许范围内")
            }
            return frontmost
        }
        throw UnifiedRuntimeError.remote("找不到可控制的前台应用")
    }

    private func decode(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UnifiedRuntimeError.invalidArguments
        }
        return value
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as AnyObject?
    }

    private func accessibilityTree(_ element: AXUIElement, depth: Int, limit: Int) -> [[String: Any]] {
        guard depth < 8 else { return [] }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
        var value = attribute(element, kAXValueAttribute) as? String ?? ""
        if value.count > 200 { value = String(value.prefix(200)) }
        var node: [String: Any] = ["role": role, "title": title, "description": description, "value": value]
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        if !children.isEmpty {
            node["children"] = children.prefix(limit).flatMap { accessibilityTree($0, depth: depth + 1, limit: max(1, limit / 2)) }
        }
        return [node]
    }

    private func find(_ root: AXUIElement, title: String?, role: String?, limit: Int) -> [[String: Any]] {
        var result: [[String: Any]] = []
        walk(root) { element in
            guard result.count < limit else { return false }
            let elementTitle = attribute(element, kAXTitleAttribute) as? String ?? ""
            let elementRole = attribute(element, kAXRoleAttribute) as? String ?? ""
            let titleMatches = title == nil || title?.isEmpty == true || elementTitle.localizedCaseInsensitiveContains(title ?? "")
            let roleMatches = role == nil || role?.isEmpty == true || elementRole == role
            if titleMatches && roleMatches {
                result.append(["role": elementRole, "title": elementTitle, "description": attribute(element, kAXDescriptionAttribute) as? String ?? ""])
            }
            return result.count < limit
        }
        return result
    }

    private func findOne(_ root: AXUIElement, title: String?, role: String?) throws -> AXUIElement {
        var match: AXUIElement?
        walk(root) { element in
            let elementTitle = attribute(element, kAXTitleAttribute) as? String ?? ""
            let elementRole = attribute(element, kAXRoleAttribute) as? String ?? ""
            let titleMatches = title == nil || title?.isEmpty == true || elementTitle.localizedCaseInsensitiveContains(title ?? "")
            let roleMatches = role == nil || role?.isEmpty == true || elementRole == role
            if titleMatches && roleMatches {
                match = element
                return false
            }
            return true
        }
        guard let match else { throw UnifiedRuntimeError.remote("找不到指定的可访问性元素") }
        return match
    }

    private func walk(_ element: AXUIElement, visit: (AXUIElement) -> Bool) {
        guard visit(element) else { return }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children.prefix(240) { walk(child, visit: visit) }
    }

    private func postKey(_ key: String) throws {
        let mapping: [String: CGKeyCode] = ["return": 36, "tab": 48, "escape": 53, "space": 49, "delete": 51, "up": 126, "down": 125, "left": 123, "right": 124]
        guard let code = mapping[key.lowercased()] else { throw UnifiedRuntimeError.remote("不支持的按键：\(key)") }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw UnifiedRuntimeError.remote("无法创建键盘事件")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func captureWindow(application: NSRunningApplication) async throws -> String {
        guard CGPreflightScreenCaptureAccess() else {
            throw UnifiedRuntimeError.remote("未获得屏幕录制权限，请在系统设置中允许 DeepSeek Code")
        }
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = shareable.windows.first(where: { $0.owningApplication?.processID == application.processIdentifier }) else {
            throw UnifiedRuntimeError.remote("无法捕获目标窗口")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * 2))
        configuration.height = max(1, Int(window.frame.height * 2))
        configuration.showsCursor = false
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: UnifiedRuntimeError.remote("截图为空"))
                }
            }
        }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-computer-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw UnifiedRuntimeError.remote("无法创建截图文件")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw UnifiedRuntimeError.remote("截图保存失败") }
        return outputURL.path
    }

    private func json(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let result = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"serialization failed\"}"
        }
        return result
    }
}
#endif
