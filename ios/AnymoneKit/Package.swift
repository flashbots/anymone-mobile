// swift-tools-version:5.9
import PackageDescription

// AnymoneFFI.xcframework and Sources/AnymoneKit/anymone_ffi.swift are build
// products of scripts/build-ios.sh, not checked in.
let package = Package(
    name: "AnymoneKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AnymoneKit", targets: ["AnymoneKit"]),
        .library(name: "AnymoneBenchKit", targets: ["AnymoneBenchKit"]),
    ],
    targets: [
        .binaryTarget(name: "AnymoneFFI", path: "AnymoneFFI.xcframework"),
        .binaryTarget(name: "AnymoneBenchFFI", path: "AnymoneBenchFFI.xcframework"),
        .target(name: "AnymoneKit", dependencies: ["AnymoneFFI"]),
        .target(name: "AnymoneBenchKit", dependencies: ["AnymoneBenchFFI"]),
    ]
)
