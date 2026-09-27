// @purpose Process entry point: creates NSApplication with AppDelegate and runs the event loop.
// @role    Top of the app; hands control to AppDelegate (or, DEBUG only, `--render-shots` to ShotRenderer).
// @deps    AppKit
// @gotcha  Runs under MainActor.assumeIsolated; the delegate must outlive app.run(). docs/modules/app/README.md
import AppKit

MainActor.assumeIsolated {
    #if DEBUG
    // Website screenshots (scripts/render-shots.sh): a separate run that never starts the normal app.
    if let i = CommandLine.arguments.firstIndex(of: "--render-shots"), i + 1 < CommandLine.arguments.count {
        ShotRenderer.run(out: URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true))
        return
    }
    #endif
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
