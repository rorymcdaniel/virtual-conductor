import AppKit
import ApplicationServices

// Query only window metadata. MuseScore's companion supplies the musical selection.
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

var result: [String: Any] = [:]
if AXIsProcessTrusted(),
   let app = NSRunningApplication.runningApplications(withBundleIdentifier: "org.musescore.MuseScore").first {
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.5)
    for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        guard let value = attribute(application, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
        let window = value as! AXUIElement
        let document = attribute(window, kAXDocumentAttribute)
        let url: URL?
        if let string = document as? String {
            url = string.hasPrefix("/") ? URL(fileURLWithPath: string) : URL(string: string)
        } else {
            url = document as? URL
        }
        guard let url, url.isFileURL, url.path.hasPrefix("/") else { continue }
        result["path"] = url.path
        if let edited = attribute(window, kAXEditedAttribute) as? Bool { result["edited"] = edited }
        break
    }
}
let data = try JSONSerialization.data(withJSONObject: result)
print(String(decoding: data, as: UTF8.self))
