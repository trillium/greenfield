// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "greenfield-inserter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "greenfield-inserter", targets: ["greenfield-inserter"]),
    ],
    targets: [
        // Everything testable: HTTP parsing, request handling, key store, de-duplication.
        .target(name: "InserterCore"),
        // The CLI / daemon entry point.
        .executableTarget(name: "greenfield-inserter", dependencies: ["InserterCore"]),
        // A tiny window with a text field that mirrors its contents to a file, used to
        // verify insertion end to end without touching a real app.
        .executableTarget(name: "testfield"),
        .testTarget(name: "InserterCoreTests", dependencies: ["InserterCore"]),
    ]
)
