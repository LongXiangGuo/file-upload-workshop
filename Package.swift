// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileUploadPlus",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        // --- Umbrella (imports all) ---
        .library(name: "FileUploadPlus", targets: ["FileUploadPlus"]),

        // --- Individual modules (按需引入) ---
        .library(name: "FileUploadPlusCore",        targets: ["FileUploadPlusCore"]),
        .library(name: "FileUploadPlusEngine",      targets: ["FileUploadPlusEngine"]),
        .library(name: "FileUploadPlusServices",    targets: ["FileUploadPlusServices"]),
        .library(name: "FileUploadPlusPipeline",    targets: ["FileUploadPlusPipeline"]),
        .library(name: "FileUploadPlusMetrics",     targets: ["FileUploadPlusMetrics"]),
        .library(name: "FileUploadPlusDownload",    targets: ["FileUploadPlusDownload"]),
        .library(name: "FileUploadPlusGRDB",        targets: ["FileUploadPlusGRDB"]),
        .library(name: "FileUploadPlusPreprocess",  targets: ["FileUploadPlusPreprocess"]),
        .library(name: "FileUploadPlusHealthCheck", targets: ["FileUploadPlusHealthCheck"]),
        .library(name: "FileUploadPlusNetwork",     targets: ["FileUploadPlusNetwork"]),
        .library(name: "FileUploadPlusAPM",         targets: ["FileUploadPlusAPM"]),
        .library(name: "FileUploadPlusEncryption",  targets: ["FileUploadPlusEncryption"]),
        .library(name: "FileUploadPlusCDN",         targets: ["FileUploadPlusCDN"]),
    ],
    targets: [
        // ===================== Core =====================
        .target(name: "FileUploadPlusCore", path: "Sources/FileUploadPlusCore"),

        // ===================== Engine =====================
        .target(name: "FileUploadPlusEngine", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusEngine"),

        // ===================== Services =====================
        .target(name: "FileUploadPlusServices", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusServices"),

        // ===================== Pipeline =====================
        .target(name: "FileUploadPlusPipeline", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusPipeline"),

        // ===================== Metrics =====================
        .target(name: "FileUploadPlusMetrics", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusMetrics"),

        // ===================== Download =====================
        .target(name: "FileUploadPlusDownload", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusDownload"),

        // ===================== GRDB =====================
        .target(name: "FileUploadPlusGRDB", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusGRDB"),

        // ===================== Preprocess =====================
        .target(name: "FileUploadPlusPreprocess", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusPreprocess"),

        // ===================== Health Check =====================
        .target(name: "FileUploadPlusHealthCheck", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusHealthCheck"),

        // ===================== Network =====================
        .target(name: "FileUploadPlusNetwork", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusNetwork"),

        // ===================== APM =====================
        .target(name: "FileUploadPlusAPM", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusAPM"),

        // ===================== Encryption =====================
        .target(name: "FileUploadPlusEncryption", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusEncryption"),

        // ===================== CDN =====================
        .target(name: "FileUploadPlusCDN", dependencies: ["FileUploadPlusCore"],
                path: "Sources/FileUploadPlusCDN"),

        // ===================== Umbrella =====================
        .target(
            name: "FileUploadPlus",
            dependencies: [
                "FileUploadPlusCore",
                "FileUploadPlusEngine",
                "FileUploadPlusServices",
                "FileUploadPlusPipeline",
                "FileUploadPlusMetrics",
                "FileUploadPlusDownload",
                "FileUploadPlusGRDB",
                "FileUploadPlusPreprocess",
                "FileUploadPlusHealthCheck",
                "FileUploadPlusNetwork",
                "FileUploadPlusAPM",
                "FileUploadPlusEncryption",
                "FileUploadPlusCDN",
            ],
            path: "Sources/FileUploadPlusUmbrella"
        ),

        // ===================== Demo =====================
        .executableTarget(
            name: "FileUploadPlusDemo",
            dependencies: ["FileUploadPlus"],
            path: "Sources/FileUploadPlusDemo"
        ),

        // ===================== Tests =====================
        .testTarget(
            name: "FileUploadPlusCoreTests",
            dependencies: ["FileUploadPlusCore"],
            path: "Tests/FileUploadPlusCoreTests"
        ),
    ]
)
