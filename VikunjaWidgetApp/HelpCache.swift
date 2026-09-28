import Foundation

/// On-disk working copy of the Help page ("Application Support/Help/"), always
/// containing a loadable `help.html` + its `site.css`/`site.js` siblings.
///
/// The hosted Help page is not a single self-contained file — it shares
/// `site.css`/`site.js` with the rest of the scottsapps.github.io marketing
/// site. So instead of caching one opaque blob, this maintains one fixed
/// working directory: seeded once from the app bundle (guaranteeing every
/// relative link resolves locally), with only `help.html` itself refreshed
/// after a successful remote fetch (the prose is what changes; the shared
/// CSS/JS are page chrome that only changes on an app update).
///
/// Thread-safety: immutable `directory`; `seedIfNeeded`/`cachedFileURL` are fast
/// synchronous file checks safe to call from the main thread.
final class HelpCache: @unchecked Sendable {
    static let shared = HelpCache()

    private let directory: URL

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = appSupport.appendingPathComponent("Help", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
    }

    /// Local file URL for the working copy of help.html, seeding the working
    /// directory from the app bundle on first call if it's empty. Returns nil
    /// only if the bundle itself is missing help.html (should never happen).
    func cachedFileURL() -> URL? {
        seedIfNeeded()
        let url = directory.appendingPathComponent("help.html")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies the bundled help.html/site.css/site.js into the working
    /// directory for any file not already present. Never overwrites an existing
    /// file, so a previously fetched fresher help.html survives an app update.
    private func seedIfNeeded() {
        let pairs: [(resource: String, ext: String, dest: String)] = [
            ("help", "html", "help.html"),
            ("site", "css", "site.css"),
            ("site", "js", "site.js"),
        ]
        for pair in pairs {
            let dest = directory.appendingPathComponent(pair.dest)
            guard !FileManager.default.fileExists(atPath: dest.path),
                  let bundled = Bundle.main.url(forResource: pair.resource, withExtension: pair.ext)
            else { continue }
            try? FileManager.default.copyItem(at: bundled, to: dest)
        }
    }

    /// Downloads the live help.html and overwrites the working copy on success.
    /// Fire-and-forget; safe to call repeatedly. Does not touch site.css/site.js —
    /// those are page chrome refreshed only by the next app update.
    func refresh(from remoteURL: URL) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty
            else { return }
            let dest = self.directory.appendingPathComponent("help.html")
            try? data.write(to: dest, options: .atomic)
        }
    }

    // MARK: - Helpers

    private func excludeFromBackup(_ url: URL) {
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }
}
