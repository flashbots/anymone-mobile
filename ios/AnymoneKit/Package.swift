// swift-tools-version:5.9
import PackageDescription

// XCFrameworks and generated binding sources are build products of
// scripts/build-ios.sh, not checked in.
let package = Package(
    name: "AnymoneKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AnymoneKit", targets: ["AnymoneKit"]),
        .library(name: "AnymoneBenchKit", targets: ["AnymoneBenchKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "AnymoneFFIBinary",
            path: "AnymoneFFI.xcframework"
        ),
        .binaryTarget(
            name: "AnymoneBenchFFIBinary",
            path: "AnymoneBenchFFI.xcframework"
        ),
        .target(
            name: "AnymoneKitFFI",
            dependencies: ["AnymoneFFIBinary"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "AnymoneBenchKitFFI",
            dependencies: ["AnymoneBenchFFIBinary"],
            publicHeadersPath: "include"
        ),
        .target(name: "AnymoneKit", dependencies: ["AnymoneKitFFI"]),
        .target(
            name: "AnymoneBenchKit",
            dependencies: ["AnymoneBenchKitFFI"]
        ),
    ]
)
