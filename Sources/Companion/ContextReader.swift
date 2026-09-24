import AppKit
import Carbon
import CoreML
import ImageIO
import ScreenCaptureKit
import Vision

enum ContextReadError: LocalizedError {
    case permission(ContextSource)
    var errorDescription: String? {
        switch self {
        case .permission(.accessibility): return "当前选择仅界面文字，请在轻言设置中授权辅助功能"
        case .permission(.screenshot): return "当前选择仅截图识别，请在轻言设置中授权屏幕录制；已开启时请退出辅助应用后重试"
        case .permission(.auto): return "猜你想说需要辅助功能或屏幕录制权限；若系统已开启，请在轻言设置中查看重新授权步骤"
        }
    }
}

// Reads the focused window of another app, in memory only. Screenshots are never written to disk.
enum ContextReader {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenGranted: Bool { CGPreflightScreenCaptureAccess() }
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    static func requestScreen() { _ = CGRequestScreenCaptureAccess() }
    // The first Chinese OCR after install or reboot can take many seconds; pay it before a guess.
    static func prepareRecognizer() {
        Task.detached(priority: .utility) {
            guard let blank = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage() else { return }
            try? VNImageRequestHandler(cgImage: blank).perform([textRequest()])
        }
    }
    // Runs on the CPU. For a window screenshot it is about as fast as the Neural Engine here
    // (0.25 s for 1970 × 1696), and it does not depend on the compiled-model cache in Caches:
    // macOS purged that cache and left empty folders, after which every Neural Engine request
    // failed (TextRecognition E5RT code 13, CRImageReaderError 1) instead of recompiling.
    private static func textRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        for (stage, devices) in (try? request.supportedComputeStageDevices) ?? [:] {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        return request
    }
    // Diagnostic: the recognizer 猜你想说 uses, on an image file, in this app's context.
    static func recognizeText(in url: URL) throws -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let request = textRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func read(_ request: ContextRequest, source: ContextSource) async throws -> ScreenContext {
        // Another app is reading a password; do not look at the screen.
        guard !IsSecureEventInputEnabled() else { return ScreenContext() }
        let useAX = source != .screenshot && accessibilityGranted
        let useScreen = source != .accessibility && screenGranted
        guard useAX || useScreen else { throw ContextReadError.permission(source) }
        let pid = request.pid
        // The input method reports the caret line in bottom-left Cocoa points; readers use top-left.
        let field = request.caret.map {
            CGRect(x: $0.minX, y: CGDisplayBounds(CGMainDisplayID()).height - $0.maxY, width: $0.width, height: $0.height)
        }
        var context = ScreenContext()
        if useAX, let read = await Task.detached(priority: .userInitiated, operation: { accessibility(pid: pid, field: field) }).value {
            context = read
        }
        // Chat and Electron apps often expose little text to accessibility; fall back to OCR.
        if useScreen, source == .screenshot || context.text.count < 40,
           let read = try await screenshot(pid: pid, field: field), read.text.count > context.text.count {
            context.text = read.text; context.source = read.source
            if !read.window.isEmpty { context.window = read.window }
        }
        context.app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        return context
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = value(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func rect(_ position: Any?, _ size: Any?) -> CGRect? {
        guard let position = position as AnyObject?, let size = size as AnyObject?,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
    private static func title(_ window: String, header: String) -> String {
        header.isEmpty || window == header ? window : window.isEmpty ? header : window + " · " + header
    }
    private static func accessibility(pid: pid_t, field caret: CGRect?) -> ScreenContext? {
        // A hung app must not stall the guess; this applies to every AX call in this process.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let app = AXUIElementCreateApplication(pid)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        var result = ScreenContext(window: value(window, kAXTitleAttribute) as? String ?? "", source: "界面文字")
        let focused = element(app, kAXFocusedUIElementAttribute)
        if let focused {
            result.field = [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                .lazy.compactMap { value(focused, $0) as? String }.first { !$0.isEmpty } ?? ""
        }
        let deadline = Date().addingTimeInterval(0.8)
        var visited = 0, items: [ScreenItem] = []
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute]
        func collect(_ node: AXUIElement, depth: Int = 0) {
            guard visited < 4000, depth < 40, Date() < deadline else { return }
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, names as CFArray, [], &values) == .success,
                  let list = values as? [Any], list.count == names.count, list[1] as? String != kAXSecureTextFieldSubrole else { return }
            if [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole].contains(list[0] as? String ?? ""),
               let text = list[2] as? String, !text.isEmpty, let frame = rect(list[4], list[5]) {
                items.append(ScreenItem(text: text, frame: frame))
            }
            for child in list[3] as? [AXUIElement] ?? [] { collect(child, depth: depth + 1) }
        }
        // Walk outward from the field so the nearest text is read first if time runs out.
        if var node = focused {
            while !CFEqual(node, window), let parent = element(node, kAXParentAttribute), Date() < deadline {
                let siblings = value(parent, kAXChildrenAttribute) as? [AXUIElement] ?? []
                guard siblings.contains(where: { CFEqual($0, node) }) else { break }
                for sibling in siblings where !CFEqual(sibling, node) { collect(sibling) }
                node = parent
            }
        } else { collect(window) }
        guard let frame = rect(value(window, kAXPositionAttribute), value(window, kAXSizeAttribute)) else { return result }
        let arranged = ContextGuess.arrange(items, field: caret ?? focused.flatMap {
            rect(value($0, kAXPositionAttribute), value($0, kAXSizeAttribute))
        }, window: frame)
        result.window = title(result.window, header: arranged.title)
        result.text = arranged.text
        return result
    }

    private static func screenshot(pid: pid_t, field: CGRect?) async throws -> ScreenContext? {
        // Front to back: the app's first normal window is the one being typed in.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let number = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && $0[kCGWindowLayer as String] as? Int == 0
        })?[kCGWindowNumber as String] as? Int else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(number) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(CGFloat(filter.pointPixelScale), 3000 / max(window.frame.width, window.frame.height, 1))
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let frame = window.frame, title = window.title ?? ""
        return try await Task.detached(priority: .userInitiated) {
            let arranged = try recognize(image, frame: frame, field: field)
            return ScreenContext(window: Self.title(title, header: arranged.title), text: arranged.text, source: "截图识别")
        }.value
    }
    private static func recognize(_ image: CGImage, frame: CGRect, field: CGRect?) throws -> (title: String, text: String) {
        let request = textRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        // Vision boxes are normalized with a bottom-left origin; items are in top-left global points.
        let items = (request.results ?? []).compactMap { observation -> ScreenItem? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return ScreenItem(text: text, frame: CGRect(x: frame.minX + box.minX * frame.width, y: frame.minY + (1 - box.maxY) * frame.height,
                                                     width: box.width * frame.width, height: box.height * frame.height))
        }
        return ContextGuess.arrange(ContextGuess.dropSmallText(items), field: field, window: frame)
    }
}
