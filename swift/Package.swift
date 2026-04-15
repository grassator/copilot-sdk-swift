// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CopilotSDK",
    products: [
        .library(name: "CopilotSDK", targets: ["CopilotSDK"]),
        .executable(name: "copilot-sdk-chat", targets: ["CopilotSDKChatSample"]),
    ],
    targets: [
        .target(name: "CopilotSDK"),
        .executableTarget(
            name: "CopilotSDKChatSample",
            dependencies: ["CopilotSDK"],
            path: "Samples/Chat/Sources/Chat"
        ),
        .testTarget(name: "CopilotSDKTests", dependencies: ["CopilotSDK"]),
    ],
    swiftLanguageModes: [.v6]
)
