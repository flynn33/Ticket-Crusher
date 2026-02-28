// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ticket-crushers",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TicketCrusherApp", targets: ["TicketCrusherApp"]),
        .executable(name: "TicketCrusherChecks", targets: ["TicketCrusherChecks"]),
        .library(name: "TicketCrusherCore", targets: ["TicketCrusherCore"]),
        .library(name: "TicketCrusherStorage", targets: ["TicketCrusherStorage"]),
        .library(name: "TicketCrusherFeatures", targets: ["TicketCrusherFeatures"]),
        .library(name: "TicketCrusherIntegrations", targets: ["TicketCrusherIntegrations"])
    ],
    targets: [
        .target(name: "TicketCrusherCore"),
        .target(
            name: "TicketCrusherStorage",
            dependencies: ["TicketCrusherCore"]
        ),
        .target(
            name: "TicketCrusherIntegrations",
            dependencies: ["TicketCrusherCore"]
        ),
        .target(
            name: "TicketCrusherFeatures",
            dependencies: ["TicketCrusherCore"]
        ),
        .executableTarget(
            name: "TicketCrusherChecks",
            dependencies: [
                "TicketCrusherCore",
                "TicketCrusherStorage",
                "TicketCrusherFeatures"
            ]
        ),
        .executableTarget(
            name: "TicketCrusherApp",
            dependencies: [
                "TicketCrusherCore",
                "TicketCrusherStorage",
                "TicketCrusherIntegrations",
                "TicketCrusherFeatures"
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
