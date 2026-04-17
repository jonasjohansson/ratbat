import Foundation

/// Asset loader for the public status page served at `GET /`.
///
/// Task 3.7 started with a triple-quoted HTML blob inline in this file.
/// Task 3.7b moves the markup, styling and JS into real files under the
/// repo's top-level `web/` directory which is bundled into the Mac app
/// (and the test bundle) as a folder-reference resource. Swift reads
/// bytes from the bundle at request time — one small `Data` per file,
/// no templating, no caching surprise beyond what the filesystem does.
///
/// In DEBUG builds the loader also looks for the `web/` folder on disk
/// (via a `JOHANSSOUND_WEB_DIR` env var or by walking up from CWD) so
/// front-end edits show up on browser refresh without rebuilding Swift.
enum StatusPage {
    /// Load a named asset from the bundled `web/` folder.
    /// Returns `nil` when the file is missing; callers should map that
    /// to an HTTP 404 rather than substituting placeholder content.
    static func asset(_ filename: String) -> Data? {
        #if DEBUG
        if let repoURL = repoWebFolder() {
            let url = repoURL.appendingPathComponent(filename)
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }
        #endif

        return Bundle.findWebAsset(filename)
    }

    /// MIME type lookup keyed on filename suffix. Kept small and local —
    /// we only serve a handful of file types (html/css/js/json/png/ico).
    /// Unknown extensions fall back to `application/octet-stream` so the
    /// browser refuses to interpret them, which is the safest default.
    static func mimeType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if lower.hasSuffix(".css")  { return "text/css; charset=utf-8" }
        if lower.hasSuffix(".js")   { return "application/javascript; charset=utf-8" }
        if lower.hasSuffix(".json") { return "application/json" }
        if lower.hasSuffix(".ico")  { return "image/x-icon" }
        if lower.hasSuffix(".png")  { return "image/png" }
        if lower.hasSuffix(".svg")  { return "image/svg+xml" }
        return "application/octet-stream"
    }

    #if DEBUG
    /// Locate the repo's `web/` folder for dev hot-reload. We try two
    /// sources, in order:
    ///
    /// 1. `JOHANSSOUND_WEB_DIR` env var — explicit override for unusual
    ///    setups (running the built app from a custom launchctl job etc).
    /// 2. Walking up from the current working directory looking for
    ///    `web/index.html`. Handles the common `xcodebuild` /
    ///    `swift test` / direct-run cases without extra config.
    ///
    /// Returns `nil` if neither locates a `web/` folder — bundle lookup
    /// then takes over.
    private static func repoWebFolder() -> URL? {
        if let dir = ProcessInfo.processInfo.environment["JOHANSSOUND_WEB_DIR"] {
            let url = URL(fileURLWithPath: dir)
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("index.html").path
            ) {
                return url
            }
        }

        var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cwd.appendingPathComponent("web/index.html")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return cwd.appendingPathComponent("web")
            }
            let parent = cwd.deletingLastPathComponent()
            if parent.path == cwd.path { break }
            cwd = parent
        }
        return nil
    }
    #endif
}

extension Bundle {
    /// Look up `filename` inside a bundled `web/` subdirectory, across
    /// every loaded bundle (main app, test bundle, frameworks). We check
    /// `Bundle.main` first for the production path, then fall back to
    /// `Bundle.allBundles` — which in the unit-test process contains the
    /// `.xctest` bundle where the `web/` folder is also copied.
    static func findWebAsset(_ filename: String) -> Data? {
        let candidates: [Bundle] = [.main] + Bundle.allBundles
        for bundle in candidates {
            if let url = bundle.url(
                forResource: filename,
                withExtension: nil,
                subdirectory: "web"
            ) {
                if let data = try? Data(contentsOf: url) {
                    return data
                }
            }
            // Some folder-reference layouts don't index individual files
            // via `url(forResource:...)` — fall back to resolving the
            // subdirectory then appending the filename manually.
            if let dirURL = bundle.resourceURL?.appendingPathComponent("web"),
               FileManager.default.fileExists(atPath: dirURL.path) {
                let fileURL = dirURL.appendingPathComponent(filename)
                if let data = try? Data(contentsOf: fileURL) {
                    return data
                }
            }
        }
        return nil
    }
}
