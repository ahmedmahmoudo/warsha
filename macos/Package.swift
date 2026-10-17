// swift-tools-version: 6.0
import PackageDescription

// The native macOS shell: a menu-bar app with a window that shows Workbench's pages, and that
// starts and supervises the Node server they talk to. `macos/build.sh` turns it into Workbench.app.
let package = Package(
  name: "Workbench",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "Workbench", path: "Sources/Workbench"),
  ]
)
