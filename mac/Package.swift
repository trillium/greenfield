// swift-tools-version:5.9
import Foundation
import PackageDescription

// The assist tools (window switcher, trackpad) share their wire formats with the phone through the kit's `KitAssist` target, so the two
// sides cannot drift. The kit is a checkout beside this repository: the same lookup as ../scripts/kit-dir.sh (PARROT_KIT_DIR first,
// then ../../parrot-kit, the sibling of the main checkout, ~/code/parrot-kit). Nothing is cloned or fetched.
func kitDirectory() -> String {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var candidates: [String] = []
    if let env = ProcessInfo.processInfo.environment["PARROT_KIT_DIR"], !env.isEmpty { candidates.append(env) }
    candidates.append(here.appendingPathComponent("../../parrot-kit").standardized.path)
    candidates.append(NSHomeDirectory() + "/code/parrot-kit")
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate + "/Package.swift") { return candidate }
    fatalError("cannot find the ParrotKit checkout (needs Package.swift); set PARROT_KIT_DIR")
}

let package = Package(
    name: "greenfield-inserter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "greenfield-inserter", targets: ["greenfield-inserter"]),
    ],
    dependencies: [
        .package(name: "ParrotKit", path: kitDirectory()),
    ],
    targets: [
        // Everything testable: HTTP parsing, request handling, key store, de-duplication, the assist tools.
        .target(name: "InserterCore", dependencies: [.product(name: "KitAssist", package: "ParrotKit")]),
        // The CLI / daemon entry point.
        .executableTarget(name: "greenfield-inserter", dependencies: ["InserterCore"]),
        // A tiny window with a text field that mirrors its contents to a file, used to
        // verify insertion end to end without touching a real app.
        .executableTarget(name: "testfield"),
        .testTarget(name: "InserterCoreTests", dependencies: ["InserterCore", .product(name: "KitAssist", package: "ParrotKit")]),
    ]
)
