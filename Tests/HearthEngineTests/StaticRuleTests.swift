#if os(macOS)
import Foundation
import Testing

/// The catalogue's S-kind rules: package settings, lints and the toolchain check, exercised as tests so the
/// trace sees them. Fixture text that a lint must catch is assembled from pieces, so this file stays clean itself.
@Suite struct StaticRuleTests {
    // MARK: E-API-1

    @Test func `E-API-1 Package.swift sets Swift 6 and warnings as errors and has no dependencies`() throws {
        let manifest = try Repo.read("Package.swift")
        #expect(manifest.hasPrefix("// swift-tools-version: 6."))
        #expect(manifest.contains("let strict: [SwiftSetting] = [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]"))
        #expect(manifest.contains("dependencies: [],"))
        #expect(!manifest.contains(".package" + "("))
        #expect(!manifest.contains("unsafeFlags"))
        #expect(try Repo.lintTree().filter { $0.contains("[deps]") || $0.contains("[concurrency]") } == [])
    }

    @Test func `E-API-1 every target carries the shared settings`() throws {
        let manifest = try Repo.read("Package.swift")
        let targets = manifest.components(separatedBy: ".target(").count - 1
            + manifest.components(separatedBy: ".testTarget(").count - 1
        let settings = manifest.components(separatedBy: "swiftSettings: strict)").count - 1
        #expect(targets == 3)
        #expect(settings == targets)
    }

    @Test func `E-API-1 the deps and concurrency lints fail on a dependency and on an escape`() throws {
        let hits = try Repo.lint(fixture: "api", [
            "Package.swift": ["let d = [.package" + "(url: \"https://example.com/x\", from: \"1.0.0\")]"],
            "Sources/Engine/A.swift": [
                "final class A: @unchecked" + " Sendable {}",
                "nonisolated" + "(unsafe) var shared = 0",
                "final class B: Sendable {}",
            ],
        ])
        #expect(hits == ["Package.swift:1: [deps]", "Sources/Engine/A.swift:1: [concurrency]", "Sources/Engine/A.swift:2: [concurrency]"])
    }

    // MARK: E-HAR-2, the lint half

    @Test func `E-HAR-2 the clock lint fails on each clock read the catalogue names`() throws {
        let reads = ["let a = Date" + "()", "let b = CACurrent" + "MediaTime()", "let c = mach_absolute" + "_time()"]
        let hits = try Repo.lint(fixture: "clock", ["Sources/Engine/A.swift": reads, "Tests/EngineTests/T.swift": reads])
        #expect(hits == [
            "Sources/Engine/A.swift:1: [clock]", "Sources/Engine/A.swift:2: [clock]", "Sources/Engine/A.swift:3: [clock]",
            "Tests/EngineTests/T.swift:1: [clock]", "Tests/EngineTests/T.swift:2: [clock]", "Tests/EngineTests/T.swift:3: [clock]",
        ])
    }

    @Test func `E-HAR-2 the clock lint exempts only the display-link adapter and the tree is clean`() throws {
        let read = "let t = CACurrent" + "MediaTime()"
        let hits = try Repo.lint(fixture: "clock-exempt", [
            "Sources/Engine/DisplayLinkAdapter.swift": [read],
            "Sources/Engine/Other.swift": ["// " + read, "let d = Date(timeIntervalSince1970: 0)", read],
        ])
        #expect(hits == ["Sources/Engine/Other.swift:3: [clock]"])
        #expect(try Repo.lintTree().filter { $0.contains("[clock]") || $0.contains("[sleep]") } == [])
    }

    // MARK: E-CORPUS-2

    @Test func `E-CORPUS-2 the manifest lint finds a reader of each kit manifest`() throws {
        let readers = ["layers", "tile", "sheet"].map { "let url = kit.appendingPathComponent(\"" + $0 + ".json\")" }
        let hits = try Repo.lint(fixture: "manifest", ["Sources/Engine/A.swift": readers, "Tests/EngineTests/T.swift": readers])
        #expect(hits == [
            "Sources/Engine/A.swift:1: [manifest]", "Sources/Engine/A.swift:2: [manifest]", "Sources/Engine/A.swift:3: [manifest]",
            "Tests/EngineTests/T.swift:1: [manifest]", "Tests/EngineTests/T.swift:2: [manifest]", "Tests/EngineTests/T.swift:3: [manifest]",
        ])
    }

    @Test func `E-CORPUS-2 the tree has no kit manifest reader`() throws {
        #expect(try Repo.lintTree().filter { $0.contains("[manifest]") } == [])
    }

    @Test func `E-CORPUS-2 a comment another json name and a doc are not hits`() throws {
        let name = "tile" + ".json"
        let hits = try Repo.lint(fixture: "manifest-edge", [
            "Sources/Engine/A.swift": ["// the kit writes " + name, "let scene = \"scene.json\"", "let x = \"subtile" + ".json\""],
            "docs/x.md": ["the kit writes " + name],
            "scripts/tool.py": ["open('" + name + "')"],
        ])
        #expect(hits == [])
    }

    // MARK: B-TOOL-1

    @Test func `B-TOOL-1 the check passes where the Metal Toolchain is installed`() throws {
        let result = try Repo.script("metal-toolchain")
        #expect(result.code == 0)
        #expect(result.output.contains("metal-toolchain: installed"))
    }

    @Test func `B-TOOL-1 a missing toolchain fails with the install command`() throws {
        let result = try Repo.script("metal-toolchain", ["--xcrun", "/usr/bin/false"])
        #expect(result.code == 1)
        #expect(result.output.contains("xcodebuild -downloadComponent metalToolchain"))
    }

    @Test func `B-TOOL-1 a missing xcrun fails the same way and the gate checks before it builds`() throws {
        let result = try Repo.script("metal-toolchain", ["--xcrun", "/nonexistent/xcrun"])
        #expect(result.code == 1)
        #expect(result.output.contains("xcodebuild -downloadComponent metalToolchain"))

        let gate = try Repo.read("scripts/gate")
        let build = try #require(gate.range(of: "def step_build(r):"))
        let check = try #require(gate.range(of: "\"scripts\", \"metal-toolchain\")", range: build.upperBound..<gate.endIndex))
        let compile = try #require(gate.range(of: "[\"swift\", \"build\"", range: build.upperBound..<gate.endIndex))
        #expect(check.lowerBound < compile.lowerBound)
        let between = gate[check.upperBound..<compile.lowerBound]
        #expect(between.contains("return \"infra\""))
    }
}
#endif
