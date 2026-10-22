// swift-tools-version: 6.2
import PackageDescription

// Warsha as a native macOS app: SwiftUI pages, a menu bar item, and Warsha's own data in
// SQLite, with no server. `macos/build.sh` turns it into Warsha.app.
let package = Package(
  name: "Warsha",
  platforms: [.macOS(.v26)],
  targets: [
    .executableTarget(name: "Warsha", path: "Sources/Warsha"),
    .testTarget(name: "WarshaTests", dependencies: ["Warsha"], path: "Tests/WarshaTests"),
  ]
)
