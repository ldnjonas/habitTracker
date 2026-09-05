// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HabitKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HabitCore", targets: ["HabitCore"]),
        .library(name: "HabitStore", targets: ["HabitStore"]),
        .library(name: "HabitSync", targets: ["HabitSync"]),
        .library(name: "HabitUI", targets: ["HabitUI"]),
    ],
    dependencies: [
        // Explizites SQL statt SwiftData: das lokale Schema soll 1:1 dem
        // späteren Postgres-Schema entsprechen, inklusive der Sync-Spalten.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Reine Domäne: keine Abhängigkeiten, kein Foundation-Calendar, kein UI.
        // Alles hier ist mechanisch nach TypeScript übersetzbar.
        .target(name: "HabitCore"),
        // Die Golden Fixtures liegen in spec/fixtures und werden über #filePath
        // gefunden, nicht ins Bundle kopiert: eine Quelle, die später auch die
        // TypeScript-Portierung liest.
        .target(
            name: "HabitStore",
            dependencies: ["HabitCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Abgleich mit dem Server. Kennt kein UI und keine Domänenlogik: er
        // schiebt Zeilen hin und her und führt einen Cursor.
        .target(name: "HabitSync", dependencies: ["HabitCore", "HabitStore"]),
        // Geteilte Views für Mac und iPhone. Bedingung, damit das trägt:
        // kein NSColor/UIColor, keine AppKit- oder UIKit-Importe, alles
        // Plattformspezifische hinter #if os(macOS).
        .target(
            name: "HabitUI",
            dependencies: ["HabitCore", "HabitStore", "HabitSync"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "HabitCoreTests", dependencies: ["HabitCore"]),
        .testTarget(name: "HabitStoreTests", dependencies: ["HabitStore"]),
        .testTarget(name: "HabitSyncTests", dependencies: ["HabitSync", "HabitStore"]),
    ]
)
