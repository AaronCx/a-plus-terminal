// swift-tools-version: 6.0

// VENDORED for a+Terminal — RoyalVNCKit 1.1.0, upstream commit
// 92d4427c73817d8f849bb289ff190aa4b40c44ea of
// https://github.com/royalapplications/royalvnc (MIT). Source targets are
// verbatim; this manifest is patched for a deterministic, minimal iOS build:
//   * CryptoSwift fork pinned by revision (upstream uses a floating branch,
//     which SPM also forbids in version-pinned dependencies — the reason
//     this package is vendored instead of referenced by tag).
//   * swift-jpeg / swift-png dropped: upstream only uses them on
//     Linux/Windows/Android, and 4.5.x pulled unvetted transitives.
//   * Windows-only vendored zlib removed (Apple platforms link system libz).
//   * Library product made STATIC (upstream ships `type: .dynamic` for its
//     C-bindings distribution): the XcodeGen-generated project embeds no
//     Frameworks/ for dynamic SPM products, so the archived app referenced
//     @rpath/RoyalVNCKit.framework that wasn't in the bundle — dyld abort at
//     launch on device (the simulator masks it by resolving @rpath into the
//     build products dir). Static links the code into the app binary; the
//     test bundle compiles against it with `link: false`, the Citadel
//     pattern.
// Source patches (each marked "a+Terminal VENDOR PATCH" in place):
//   * PointerPos pseudo-encoding (-232, UltraVNC extension) implemented and
//     advertised alongside Cursor: new PointerPosEncoding.swift, plumbed
//     through VNCFramebuffer(+Delegate) and VNCConnection(+Framebuffer,
//     +Delegate, Delegate protocol + conformer stubs) as
//     connection(_:didMovePointerToX:y:). Rationale: macOS Screen Sharing
//     composites no cursor into the framebuffer regardless of what the
//     client advertises (field-verified on build 33), so a visible remote
//     cursor requires client-side rendering — Cursor gives the shape,
//     PointerPos (when the server supports it) or locally injected input
//     gives the position.
// Non-manifest trims: Design/, Bindings/, android scripts (no code targets).

import PackageDescription

let swiftLanguageMode = SwiftLanguageMode.v5

let zTarget = Target.target(name: "Z", linkerSettings: [
    .linkedLibrary("z")
])

let d3desTarget = Target.target(name: "d3des")

let package = Package(
    name: "RoyalVNCKit",

    platforms: [
        .macOS(.v11),
        .iOS(.v15),
        .macCatalyst(.v15),
        .tvOS(.v15),
        .visionOS(.v1)
    ],

    products: [
        .library(
            name: "RoyalVNCKit",
            targets: [ "RoyalVNCKit" ]
        ),

        .executable(name: "RoyalVNCKitDemo",
                    targets: [ "RoyalVNCKitDemo" ])
    ],

    dependencies: [
        .package(url: "https://github.com/royalapplications/CryptoSwift.git", revision: "a59b4d91ebb22011656c830f874fe7152e183a57"),
    ],

    targets: [
        .target(
            name: "RoyalVNCKitC"
        ),

        .target(
            name: "RoyalVNCKit",

            dependencies: [
                "RoyalVNCKitC",
                .byName(name: d3desTarget.name),
                .byName(name: zTarget.name),
                .byName(name: "CryptoSwift"),
            ],

            swiftSettings: [
                .swiftLanguageMode(swiftLanguageMode),

                .unsafeFlags([
                    "-enable-library-evolution"
                ])
            ]
        ),

        d3desTarget,
        zTarget,

        .executableTarget(
            name: "RoyalVNCKitDemo",
            dependencies: [ "RoyalVNCKit" ]
        ),

        .executableTarget(
            name: "RoyalVNCKitCDemo",
            dependencies: [ "RoyalVNCKit" ]
        )
    ]
)
