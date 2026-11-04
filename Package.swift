// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SuperCoreGraphicLayer",
    platforms: [.iOS(.v16)],
    products: [.library(name: "SCGLayer", targets: ["SCGLayer"])],
    targets: [
        .target(
            name: "SCGLayer",
            path: "Sources/SCGLayer",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"), .linkedFramework("UIKit"), .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"), .linkedFramework("IOSurface")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
