// swift-tools-version: 5.9
import PackageDescription
import Foundation

let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/calling-native").path
let hasNativeCalling = ["libvo-amrwbenc.a", "libopencore-amrwb.a", "libsrtp2.a"].allSatisfy {
    FileManager.default.fileExists(atPath: native + "/lib/" + $0)
}

let package = Package(
    name: "GalaxyContinuityLab", platforms: [.macOS(.v13)],
    products: [.library(name: "ContinuityCore", targets: ["ContinuityCore"]),
               .executable(name: "continuity", targets: ["ContinuityCLI"]),
               .executable(name: "GalaxyContinuityLab", targets: ["ContinuityApp"])],
    targets: [.target(name: "ContinuityCore", dependencies: hasNativeCalling ? ["CallingMediaC"] : []), .executableTarget(name: "ContinuityCLI", dependencies: ["ContinuityCore"]),
              .executableTarget(name: "ContinuityApp", dependencies: ["ContinuityCore"]),
              .testTarget(name: "ContinuityCoreTests", dependencies: hasNativeCalling ? ["ContinuityCore", "CallingMediaC"] : ["ContinuityCore"])] + (hasNativeCalling ? [
                .target(name: "CallingMediaC", cSettings: [.unsafeFlags(["-I" + native + "/include"])], linkerSettings: [
                    .unsafeFlags([native + "/lib/libsrtp2.a", native + "/lib/libopencore-amrwb.a", native + "/lib/libvo-amrwbenc.a"]), .linkedLibrary("c++")
                ])] : []))
