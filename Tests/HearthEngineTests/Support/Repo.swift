#if os(macOS)
import Foundation

/// The checkout this test file was compiled from, and the tools the static rules are written in.
enum Repo {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Runs a repo script with `python3 -I` and returns its exit code and output.
    static func script(_ name: String, _ arguments: [String] = []) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", root.appendingPathComponent("scripts/\(name)").path] + arguments
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Lints a throwaway tree holding `files` (path to lines) and returns the hits as `path:line: [rule]`.
    static func lint(fixture name: String, _ files: [String: [String]]) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearth-lint-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (path, lines) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        return hits(try script("lint.py", ["--root", directory.path]).output)
    }

    /// The lint's hits on this checkout.
    static func lintTree() throws -> [String] {
        hits(try script("lint.py").output)
    }

    private static func hits(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let end = line.range(of: "]") else { return nil }
            return line.contains(": [") ? String(line[..<end.upperBound]) : nil
        }
    }

    /// Every file under `Sources/` and `Tests/`, relative to the root.
    static func sourceFiles() -> [String] {
        var out = [String]()
        for top in ["Sources", "Tests"] {
            let base = root.appendingPathComponent(top)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(top + String(url.path.dropFirst(base.path.count)))
            }
        }
        return out.sorted()
    }

    /// Paths that hold image or texture data. The synthetic tier may have none (E-CORPUS-1).
    static func binaryAssets(in paths: [String]) -> [String] {
        let extensions: Set<String> = [
            "png", "jpg", "jpeg", "heic", "tga", "tif", "tiff", "bmp", "gif", "webp", "exr", "hdr", "ktx", "ktx2",
            "astc", "pvr", "dds", "raw", "bin",
        ]
        return paths.filter { extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
    }
}
#endif
