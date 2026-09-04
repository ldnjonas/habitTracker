// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HabitKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HabitCore", targets: ["HabitCore"]),
    ],
    targets: [
        // Reine Domäne: keine Abhängigkeiten, kein Foundation-Calendar, kein UI.
        // Alles hier ist mechanisch nach TypeScript übersetzbar.
        .target(name: "HabitCore"),
        // Die Golden Fixtures liegen in spec/fixtures und werden über #filePath
        // gefunden, nicht ins Bundle kopiert: eine Quelle, die später auch die
        // TypeScript-Portierung liest.
        .testTarget(name: "HabitCoreTests", dependencies: ["HabitCore"]),
    ]
)
