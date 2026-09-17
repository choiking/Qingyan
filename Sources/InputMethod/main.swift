import AppKit
import InputMethodKit

let args = CommandLine.arguments
if args.count == 4 && args[1] == "--deploy-rime" {
    LIRime.startShared(args[2], user: args[3], deploy: true)
    let engine = LIRime()
    guard engine.open() else { fputs("Rime schema deployment failed\n", stderr); exit(1) }
    print("Rime schema deployed")
    exit(0)
}
try LocalPaths.prepare()
LocalPaths.cleanStaleSessions()
LIRime.startShared(RimeData.shared.path, user: RimeData.user.path, deploy: false)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let server = IMKServer(name: "LocalInput_Connection", bundleIdentifier: Bundle.main.bundleIdentifier!)
guard server != nil else { fputs("Cannot start InputMethodKit server\n", stderr); exit(1) }
app.run()
