import AppKit

// `Lidless --export-icons <directory>` renders the artwork instead of starting the app:
// scripts/bundle.sh uses it to build AppIcon.icns.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--export-icons"), flag + 1 < arguments.count {
    let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    do {
        try AppIconArtwork.exportIconset(to: directory.appendingPathComponent("AppIcon.iconset"))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("lidless: could not export icons: \(error)\n".utf8))
        exit(1)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
