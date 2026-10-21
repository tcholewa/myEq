// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "myEq",
    platforms: [.macOS("27.0")],
    products: [.library(name: "MyEqCore", targets: ["MyEqCore"]), .executable(name: "myEq", targets: ["MyEqApp"])],
    targets: [
        .target(name: "CDSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "CTransport", dependencies: ["CDSP"], publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-fobjc-arc", "-fblocks"])], linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("AudioToolbox")]),
        .target(name: "MyEqCore", dependencies: ["CDSP", "CTransport"]),
        .executableTarget(name: "MyEqApp", dependencies: ["MyEqCore"]),
        .testTarget(name: "MyEqCoreTests", dependencies: ["MyEqCore", "CDSP"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
