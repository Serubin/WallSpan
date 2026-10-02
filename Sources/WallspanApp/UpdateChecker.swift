// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation

/// The two halves that fall behind independently: the app bundle, and whichever `wallspan`
/// it resolved. The cask and the formula ship from one release but upgrade separately.
struct LocalBuilds {
    var cli: SemanticVersion?
    var cliSource: InstallSource = .other
    var app: SemanticVersion?
    var appSource: InstallSource = .other

    /// The half that is furthest behind, which is the one worth reporting. Nil when neither
    /// half reports a version this build is willing to compare.
    var oldest: SemanticVersion? { [cli, app].compactMap { $0 }.min() }

    static func current(resolution: BinaryResolver.Resolution?) -> LocalBuilds {
        var builds = LocalBuilds()
        builds.appSource = InstallSource.app()
        if let resolution { builds.cliSource = InstallSource.cli(resolution.url) }

        if let pretend = UserDefaults.standard.string(forKey: UpdateChecker.Keys.pretendVersion),
           let version = SemanticVersion(pretend) {
            UpdateChecker.log("UpdatePretendVersion is set — pretending this install is \(version)")
            builds.cli = version
            return builds
        }

        // A CLI that reports no channel predates the field, so its `version` may be equally
        // absent; a `local` one is a working tree whose fix is `git pull`, not a download.
        if let resolution, resolution.version.version != "unknown",
           ["release", "snapshot", "dev"].contains(resolution.version.channel) {
            builds.cli = SemanticVersion(resolution.version.version)
        }

        // Rejected unless it is a plain release: `Scripts/make-app.sh` falls back to `git
        // describe` for a hand build, and `0.1.0-3-gabc1234` reads as *older* than 0.1.0.
        if let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String, let version = SemanticVersion(short), version.prerelease.isEmpty {
            builds.app = version
        }
        return builds
    }
}

/// A newer release, and what to do about it given how this copy was installed.
struct UpdateOffer {
    let latest: SemanticVersion
    let releaseURL: URL
    /// Empty when nothing Homebrew manages is behind, in which case the release page is the
    /// whole answer and the menu item opens it directly.
    let commands: [String]
    /// Which half is behind, and at what version.
    let behind: String

    static func make(tag: String, builds: LocalBuilds) -> UpdateOffer? {
        guard let latest = SemanticVersion(tag), let oldest = builds.oldest, oldest < latest,
              let url = UpdateChecker.releaseURL(tag: tag)
        else { return nil }

        var commands: [String] = []
        var behind: [String] = []
        if let cli = builds.cli, cli < latest {
            behind.append("the wallspan CLI is \(cli)")
            // A bundled CLI is upgraded by upgrading the app, so it inherits that source.
            let source = builds.cliSource == .bundledWithApp ? builds.appSource : builds.cliSource
            if let command = source.upgradeCommand { commands.append(command) }
        }
        if let app = builds.app, app < latest {
            behind.append("this app is \(app)")
            if let command = builds.appSource.upgradeCommand { commands.append(command) }
        }

        return UpdateOffer(
            latest: latest, releaseURL: url,
            commands: commands.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
            behind: behind.joined(separator: ", and ")
        )
    }
}

/// One unauthenticated GET of the GitHub releases endpoint, at most daily, and nothing
/// else. Off unless the user asks for it — see the update section of the README, which
/// states exactly what this sends.
final class UpdateChecker {
    enum Outcome {
        case available(UpdateOffer)
        case upToDate(latest: SemanticVersion)
        /// Running a snapshot newer than any release, which is where every contributor is.
        case ahead(latest: SemanticVersion)
        case failed(String)
        /// Throttled, or nothing this build is willing to compare.
        case skipped
    }

    enum Keys {
        static let automatic = "CheckForUpdatesAutomatically"
        static let lastCheckedAt = "LastUpdateCheckedAt"
        static let lastSeenTag = "LastSeenReleaseTag"
        static let pretendVersion = "UpdatePretendVersion"
        static let feedURL = "UpdateFeedURL"
    }

    private static let endpoint =
        URL(string: "https://api.github.com/repos/Serubin/WallSpan/releases/latest")!
    private let defaults = UserDefaults.standard
    private let session: URLSession
    private let redirects = RedirectGuard()
    /// Main-thread only, like every other piece of state in this app.
    private var inFlight = false
    private var pending: [(Outcome) -> Void] = []
    private var lastFailureAt: Date?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        // An offline machine has to fail fast rather than hold a task open until the network
        // comes back, since the manual check is waiting on an answer to put in an alert.
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }

    /// `bool(forKey:)` answers false for an absent key, so the absence of a
    /// `register(defaults:)` is what makes this off by default.
    var automatic: Bool {
        get { defaults.bool(forKey: Keys.automatic) }
        set { defaults.set(newValue, forKey: Keys.automatic) }
    }

    /// The last tag seen, this launch or a previous one — a fact, not a verdict. Whether it
    /// constitutes an update is decided against the current resolution when the menu is
    /// drawn, so re-resolving the binary needs no invalidation here.
    var lastSeenTag: String? {
        guard let tag = defaults.string(forKey: Keys.lastSeenTag),
              SemanticVersion.isPlausibleTag(tag) else { return nil }
        return tag
    }

    /// `force` is the manual item, which bypasses the once-a-day floor. Call on the main
    /// queue; `completion` runs exactly once, on the caller's stack when there is nothing
    /// to ask and on the main queue when an answer lands.
    func check(force: Bool, against builds: LocalBuilds,
               completion: @escaping (Outcome) -> Void) {
        guard builds.oldest != nil else { return completion(.skipped) }
        // A second ask joins the request already in flight. Bouncing it would let a manual
        // check land on a quiet one and visibly answer nothing at all.
        if inFlight { return pending.append(completion) }
        guard force || mayCheckAutomatically() else { return completion(.skipped) }

        inFlight = true
        pending = [completion]
        session.dataTask(with: request()) { data, response, error in
            let result = Self.tag(from: data, response: response, error: error)
            DispatchQueue.main.async {
                self.inFlight = false
                let outcome: Outcome
                switch result {
                case .failure(let why):
                    self.lastFailureAt = Date()
                    Self.log("update check failed: \(why)")
                    outcome = .failed(why)
                case .tag(let tag):
                    outcome = self.record(tag: tag, builds: builds)
                }
                let waiting = self.pending
                self.pending = []
                waiting.forEach { $0(outcome) }
            }
        }.resume()
    }

    // MARK: - deciding

    /// Validated before it is persisted, not only on the way back out: a tag that fails here
    /// would otherwise sit in the plist being silently ignored forever.
    private func record(tag: String, builds: LocalBuilds) -> Outcome {
        guard SemanticVersion.isPlausibleTag(tag), let latest = SemanticVersion(tag) else {
            return .failed("the latest release has an unreadable tag")
        }
        defaults.set(tag, forKey: Keys.lastSeenTag)
        defaults.set(Date(), forKey: Keys.lastCheckedAt)

        if let offer = UpdateOffer.make(tag: tag, builds: builds) { return .available(offer) }
        guard let oldest = builds.oldest else { return .skipped }
        return oldest > latest ? .ahead(latest: latest) : .upToDate(latest: latest)
    }

    /// The persisted floor governs success only. Writing it on a failure would let one
    /// offline launch suppress checking for a day, so failures get an in-memory hour.
    private func mayCheckAutomatically() -> Bool {
        if let failed = lastFailureAt, Date().timeIntervalSince(failed) < 3600 { return false }
        guard let last = defaults.object(forKey: Keys.lastCheckedAt) as? Date else { return true }
        let age = Date().timeIntervalSince(last)
        // A negative age is a clock that moved backwards, which must not wedge the check.
        return age >= 86_400 || age < 0
    }

    // MARK: - the request

    private func request() -> URLRequest {
        var request = URLRequest(url: feed())
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects a request with no User-Agent, and URLSession's default carries the
        // app version and the exact macOS build — a far better fingerprint than a version.
        request.setValue("Wallspan", forHTTPHeaderField: "User-Agent")
        // Pinned for the same reason: URLSession derives this one from the user's language
        // list, which is a fingerprint bit the README promises is not sent.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        // No If-None-Match, ever: a persisted ETag echoed back each launch is a per-install
        // identifier, which is the one thing this check promises not to send.
        return request
    }

    /// `UpdateFeedURL` points the check at a local fixture for testing. The host is pinned
    /// too, so a stray plist write cannot aim the request at somewhere else entirely.
    private func feed() -> URL {
        guard let raw = defaults.string(forKey: Keys.feedURL), let url = URL(string: raw)
        else { return Self.endpoint }

        let loopback = url.host == "localhost" || url.host == "127.0.0.1"
        guard (url.scheme == "https" && url.host == "api.github.com") || url.scheme == "file"
                || (url.scheme == "http" && loopback) else {
            Self.log("UpdateFeedURL is not api.github.com, a file or loopback — ignoring it")
            return Self.endpoint
        }
        Self.log("UpdateFeedURL is set — checking \(url.absoluteString)")
        return url
    }

    private struct Release: Decodable {
        let tag: String
        enum CodingKeys: String, CodingKey { case tag = "tag_name" }
    }

    /// `/releases/latest` already excludes drafts and prereleases, which is what makes one
    /// field enough. A non-200 is a failure outright; the rate-limit headers go unread.
    private enum Fetched {
        case tag(String)
        case failure(String)
    }

    private static func tag(from data: Data?, response: URLResponse?,
                            error: Error?) -> Fetched {
        if let error { return .failure(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return .failure("GitHub answered \(http.statusCode)")
        }
        guard let data, !data.isEmpty, data.count <= 512 * 1024 else {
            return .failure("no usable answer from GitHub")
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return .failure("could not read the latest release")
        }
        return .tag(release.tag)
    }

    /// Built here rather than taken from the response's `html_url`: this feeds
    /// `NSWorkspace.open`, so no part of it comes from the network.
    static func releaseURL(tag: String) -> URL? {
        guard SemanticVersion.isPlausibleTag(tag),
              let url = URL(string: "https://github.com/Serubin/WallSpan/releases/tag/\(tag)"),
              url.scheme == "https", url.host == "github.com"
        else { return nil }
        return url
    }

    static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// Refuses to follow a redirect off GitHub. The 3xx then fails the status check, which is
/// the outcome a hijacked response should have.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host
        let allowed = request.url?.scheme == "https"
            && (host == "api.github.com" || host == "github.com")
        completionHandler(allowed ? request : nil)
    }
}
