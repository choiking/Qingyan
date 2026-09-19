import Carbon
import Foundation

let id = "org.localinput.inputmethod.LocalInput"
func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
}
func sources() -> [TISInputSource] {
    TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
}
func check(_ status: OSStatus, _ message: String) {
    guard status == noErr else { fputs("\(message): OSStatus \(status)\n", stderr); exit(1) }
}
let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "register":
    guard arguments.count == 3 else { exit(2) }
    check(TISRegisterInputSource(URL(fileURLWithPath: arguments[2]) as CFURL), "Register input source")
    guard let source = sources().first(where: { property($0, kTISPropertyInputSourceID) as? String == id }) else {
        fputs("Registered bundle; log out and back in if the input source is not listed yet.\n", stderr); exit(1)
    }
    check(TISEnableInputSource(source), "Enable input source")
    print("Enabled 轻言输入法. Your selected input source has not been changed.")
case "disable":
    if let source = sources().first(where: { property($0, kTISPropertyInputSourceID) as? String == id }) {
        if property(source, kTISPropertyInputSourceIsSelected) as? Bool == true {
            let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
            check(TISSelectInputSource(fallback), "Switch to ASCII keyboard before uninstall")
        }
        check(TISDisableInputSource(source), "Disable input source")
    }
case "status":
    for source in sources() {
        let sourceID = property(source, kTISPropertyInputSourceID) as? String ?? ""
        if sourceID == id || property(source, kTISPropertyInputSourceIsSelected) as? Bool == true {
            print("\(sourceID) enabled=\(property(source, kTISPropertyInputSourceIsEnabled) ?? false as AnyObject) selected=\(property(source, kTISPropertyInputSourceIsSelected) ?? false as AnyObject)")
            print("  name=\(property(source, kTISPropertyLocalizedName) ?? "" as AnyObject)")
            print("  icon=\(property(source, kTISPropertyIconImageURL) ?? "" as AnyObject)")
        }
    }
default: fputs("Usage: input-source register APP | status | disable\n", stderr); exit(2)
}
