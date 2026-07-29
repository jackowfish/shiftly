// swift-tools-version: 5.9
import PackageDescription

// This does not build the app. `swift build` produces a bare binary; a .app
// needs the Info.plist, the icon, the entitlements and a signature, which is
// what build.sh assembles. This exists so editors can resolve the module.
//
// Without it SourceKit analyses each file alone and reports every cross-file
// symbol as missing, which buries real diagnostics in hundreds of fake ones.
let package = Package(
    name: "Shiftly",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Shiftly", path: "Sources")
    ]
)
