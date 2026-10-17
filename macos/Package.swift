// swift-tools-version: 6.2
import PackageDescription

// Workbench as a native macOS app: SwiftUI pages, a menu bar item, and Workbench's own data in
// SQLite, with no server. `macos/build.sh` turns it into Workbench.app.
let package = Package(
  name: "Workbench",
  platforms: [.macOS(.v26)],
  targets: [
    .executableTarget(name: "Workbench", path: "Sources/Workbench"),
    .testTarget(name: "WorkbenchTests", dependencies: ["Workbench"], path: "Tests/WorkbenchTests"),
  ]
)
