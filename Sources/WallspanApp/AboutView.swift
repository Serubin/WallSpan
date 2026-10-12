// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import SwiftUI

/// About, and the only place the CLI diagnostics are visible: which `wallspan` the app
/// settled on, which candidates it passed over, and the log the background agent writes.
struct AboutView: View {
    @ObservedObject var model: AboutModel
    var onCheckForUpdates: () -> Void
    var onClose: () -> Void

    private var info: AboutInfo { model.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            identity
            Divider()
            cli
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 420)
    }

    // MARK: - pieces

    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            icon
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Wallspan").font(.title2).fontWeight(.semibold)
                Text(info.appVersion.map { "Version \($0)" } ?? "Development build")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Created by Solomon Rubin (serubin)")
                    .font(.callout)
                    .padding(.top, 4)
                if let copyright = info.copyright {
                    Text(copyright)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// `applicationIconImage` is the bundle's icon; under `swift run` there is no bundle to
    /// take one from, so the menu bar glyph stands in rather than nothing.
    private var icon: Image {
        if let appIcon = NSApp.applicationIconImage { return Image(nsImage: appIcon) }
        return Image(nsImage: BrandGlyph.menuBar)
    }

    @ViewBuilder
    private var cli: some View {
        if let resolution = info.resolution {
            VStack(alignment: .leading, spacing: 3) {
                Text("CLI \(resolution.version.summary)").font(.callout)
                Text("Using the copy from \(resolution.source.rawValue):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(resolution.url.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(resolution.url.path)

                if !resolution.newer.isEmpty {
                    newerNotice(resolution)
                }

                let skipped = resolution.rejected.filter { $0.newer == nil }
                if !skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(skipped.enumerated()), id: \.offset) { _, candidate in
                            Text("Skipped \(candidate.url.path) — \(candidate.reason)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help("\(candidate.url.path) — \(candidate.reason)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
        } else {
            Label("No usable wallspan binary was found.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Informational, not a warning: a CLI ahead of this app is a normal state, and the
    /// fallback named here is fully working.
    private func newerNotice(_ resolution: BinaryResolver.Resolution) -> some View {
        let fallback = resolution.source == .bundled
            ? "the copy bundled with the app" : resolution.url.path
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(resolution.newer.enumerated()), id: \.offset) { _, rejection in
                let sentence = newerSentence(rejection, fallback: fallback)
                Label(sentence, systemImage: "info.circle")
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(sentence)
            }
            HStack(spacing: 8) {
                // Conditional: a development CLI can be ahead of every release there is.
                let them = resolution.newer.count == 1 ? "it" : "them"
                Text("A newer Wallspan may understand \(them).")
                Button("Check for Updates…", action: onCheckForUpdates)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func newerSentence(_ rejection: BinaryResolver.Rejection, fallback: String) -> String {
        let schema = rejection.newer?.schema ?? 0
        // Self-reported by a binary this app does not understand, so bounded before display.
        let version = rejection.newer?.version.map { v in
            v.count > 40 ? " \(v.prefix(40))…" : " \(v)"
        } ?? ""
        return "Your wallspan\(version) at \(rejection.url.path) uses a newer contract "
            + "(schema \(schema); this app reads up to \(Contract.maximumSchema)), "
            + "so \(fallback) is in use."
    }

    private var footer: some View {
        HStack {
            Button("Open Log", action: openLog)
                .disabled(readableLog == nil)
                .help(readableLog
                      ?? "Nothing has been logged yet. The background agent writes the log "
                         + "the first time it runs.")

            Spacer()

            Button("Close", action: onClose).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - the log

    /// Nil unless the file is actually there: `NSWorkspace.open` on a missing path fails
    /// silently, which is indistinguishable from a button that does nothing.
    private var readableLog: String? {
        guard let path = info.logPath, FileManager.default.fileExists(atPath: path)
        else { return nil }
        return path
    }

    private func openLog() {
        guard let path = readableLog else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
