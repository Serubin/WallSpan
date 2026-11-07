// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import Foundation
import Security

/// One fixed POST a local day to the project's Plausible server, so the daily pageview total
/// reads as a count of daily users. A failure retries hourly. On unless the user turns it off
/// — see the usage section of the README, which states exactly what this sends.
final class UsagePing {
    enum Keys {
        static let disabled = "DisableDailyUsagePing"
        static let lastSentDay = "LastUsagePingDay"
        static let endpoint = "UsagePingURL"
    }

    private static let production = URL(string: "https://analytics.serubin.net/api/event")!
    /// Fixed apart from the version, so no locale or machine detail can ever drift into it.
    private static let body = Data(
        #"{"name":"pageview","url":"app://wallspan/\#(version)","domain":"wallspan.serubin.net"}"#
            .utf8)

    /// Re-rendered from the parse rather than sent as read, so only digits, dots and a
    /// `-beta.N` or `-rc.N` can reach the request.
    private static let version: String = {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String, let parsed = SemanticVersion(short),
            parsed.prerelease.isEmpty || parsed.isBeta
        else { return "unknown" }
        return parsed.description
    }()

    private let defaults = UserDefaults.standard
    private let session: URLSession
    private let redirects = RefuseRedirects()
    /// Main-thread only, like every other piece of state in this app.
    private var inFlight = false
    private var timer: Timer?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }

    /// `bool(forKey:)` answers false for an absent key, which is what makes this on by default.
    var enabled: Bool {
        get { !defaults.bool(forKey: Keys.disabled) }
        set { defaults.set(!newValue, forKey: Keys.disabled) }
    }

    /// Safe to call repeatedly. Hourly so a Mac that is never restarted still rolls over to
    /// the next day; a tick with nothing due makes no request.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.sendIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.sendIfDue() }
    }

    private func sendIfDue() {
        guard enabled, !inFlight, let target = target() else { return }
        let today = Self.day(Date())
        guard let last = defaults.string(forKey: Keys.lastSentDay) else {
            // The first launch only starts the clock, so nothing leaves before the switch is findable.
            defaults.set(today, forKey: Keys.lastSentDay)
            return
        }
        guard last != today else { return }

        inFlight = true
        session.dataTask(with: request(to: target)) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async {
                self.inFlight = false
                // A failure leaves the marker alone, so the next hourly tick tries again.
                guard error == nil, let status, (200..<300).contains(status) else { return }
                self.defaults.set(today, forKey: Keys.lastSentDay)
            }
        }.resume()
    }

    private func request(to url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Self.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Pinned: URLSession's defaults would report the app version, macOS build and languages.
        request.setValue("Wallspan", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// `UsagePingURL` redirects a test to loopback, and to nowhere else.
    private func target() -> URL? {
        if let raw = defaults.string(forKey: Keys.endpoint), let url = URL(string: raw),
           url.scheme == "http", url.host == "127.0.0.1" || url.host == "localhost" {
            return url
        }
        return Self.isOfficialBuild ? Self.production : nil
    }

    /// Only release.yml holds the Developer ID, so hand builds and forks never count. The bundle
    /// version can't decide this: a hand build at a clean tag reports a plain release.
    private static let isOfficialBuild: Bool = {
        let developerID = "anchor apple generic and certificate leaf[subject.OU] = \"66D6Z42VJF\""
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(developerID as CFString, [], &requirement)
                == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }()

    /// Local rather than UTC, and never sent: it only decides whether today is already done.
    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
