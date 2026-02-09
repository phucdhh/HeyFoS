#!/usr/bin/env swift

import Foundation

// Simple test script to process tiff-samples
// Usage: swift test-process.swift

print("Starting HeyFoS test with tiff-samples/")

let startTime = Date()

// Build and run
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
task.arguments = [
    "run", "heyfos-cli",
    "--input", "tiff-samples/",
    "--output", "result.tiff",
    "--method", "laplacian",
    "--pyramid-blending",
    "--verbose"
]
task.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

do {
    try task.run()
    task.waitUntilExit()
    
    let elapsed = Date().timeIntervalSince(startTime)
    
    if task.terminationStatus == 0 {
        print("\n✓ Success!")
        print("⏱  Processing time: \(String(format: "%.1f", elapsed))s")
        
        // Check result file
        if FileManager.default.fileExists(atPath: "result.tiff") {
            let attrs = try FileManager.default.attributesOfItem(atPath: "result.tiff")
            let size = attrs[.size] as? UInt64 ?? 0
            print("📁 Result size: \(size / 1024 / 1024)MB")
        }
    } else {
        print("❌ Failed with code \(task.terminationStatus)")
    }
} catch {
    print("❌ Error: \(error)")
}
