import Foundation
import Observation
import os

/// FR-10.8: tells the user when a newer release exists, and how to get it.
///
/// Outside a store nothing else carries a published fix to the person it fixes
/// something for — there is no App Store to notice a new version, and a
/// downloaded `.app` has no updater of its own. So the app asks GitHub, which
/// is where FR-10.1 already says the releases live.
///
/// **Nothing about the user or their library is reported.** The check is a
/// plain unauthenticated `GET` of the repository's "latest release" endpoint,
/// with no query, no body, no identifier of any kind, and the answer is
/// compared against the running bundle's own version locally. What the request
/// unavoidably carries — that some copy of Alpenglow asked, from some address —
/// is the irreducible cost of asking at all, which is why FR-10.8 makes the
/// asking conditional on the user's agreement rather than assuming it. Until
/// they agree, no request is made: `consent` is unset, and every entry point
/// checks it first.
///
/// The consent is a three-state value on purpose. "Not asked yet" is not the
/// same as "asked and declined": the first is what makes the app put the
/// question once, and the second is what stops it asking again.
@MainActor
@Observable
final class UpdateCheck {
    /// One per app. The consent is one answer, the result is one fact, and
    /// two places show them — the Library tab's notice and the switch in
    /// Settings, which on the Mac is a separate scene with no way to share
    /// view state. A shared instance is how those two agree.
    static let shared = UpdateCheck()

    private init() {
        consent = UserDefaults.standard.object(forKey: Self.consentDefaultsKey) as? Bool
    }

    /// What the last check found. `unknown` covers both "not checked" and
    /// "checked and failed" — `lastError` distinguishes them, and FR-8.12
    /// requires the failure be visible rather than read as "up to date".
    enum Availability: Equatable {
        case unknown
        case upToDate
        case available(version: String, url: URL)
    }

    private(set) var availability: Availability = .unknown
    private(set) var lastError: String?
    private(set) var isChecking = false

    private let log = Logger(subsystem: "space.remco.Alpenglow", category: "UpdateCheck")

    /// The repository the releases come from — a fact about the project, not
    /// about any machine (FR-10.7). It is the same repository README and
    /// CHANGELOG point at.
    private nonisolated static let repository = "remco-space/Alpenglow"

    private static let consentDefaultsKey = "UpdateCheck.consent"

    /// nil until the user has been asked (FR-10.8's "only with their
    /// agreement" — an unanswered question is not agreement).
    ///
    /// Stored rather than read back from `UserDefaults` on demand, so the
    /// switch in Settings flips the moment it is used: `@Observable` tracks
    /// stored properties, and a computed one reading defaults would leave the
    /// control showing the old answer until something else happened to
    /// invalidate the view.
    private(set) var consent: Bool?

    var hasBeenAsked: Bool { consent != nil }

    /// The user's answer, from the one-time ask or from the settings switch
    /// that lets them change their mind. Agreeing checks straight away, so the
    /// answer to "is there a newer one?" arrives with the agreement rather
    /// than at some later launch. Withdrawing forgets what the last check
    /// found, so nothing keeps telling them about a release they have said
    /// they don't want to hear about.
    func setConsent(_ agreed: Bool) {
        consent = agreed
        UserDefaults.standard.set(agreed, forKey: Self.consentDefaultsKey)
        if agreed {
            Task { await check() }
        } else {
            availability = .unknown
            lastError = nil
        }
    }

    /// Checks, but only if the user has agreed. This is the entry point every
    /// automatic caller uses.
    func checkIfAgreed() async {
        guard consent == true else { return }
        await check()
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await Self.latestRelease()
            let current = AppIdentity.version
            if Self.isNewer(release.version, than: current) {
                availability = .available(version: release.version, url: release.url)
                log.info("A newer release exists: \(release.version, privacy: .public) (running \(current, privacy: .public))")
            } else {
                availability = .upToDate
            }
            lastError = nil
        } catch {
            // Never silently swallowed (FR-8.12): a check that failed must not
            // read as "you are up to date".
            availability = .unknown
            lastError = error.localizedDescription
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: The request

    /// The two fields of GitHub's release JSON this needs: what the release is
    /// called, and where a person goes to get it.
    private nonisolated struct LatestRelease: Decodable {
        let tag: String
        let page: URL

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
        }
    }

    private nonisolated static func latestRelease() async throws -> (version: String, url: URL) {
        let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // The answer changes at most once per release, and a stale one would
        // be a wrong answer for as long as the cache held it.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateCheckError.badResponse(status: http.statusCode)
        }
        let release = try JSONDecoder().decode(LatestRelease.self, from: data)
        // The release workflow refuses to publish a tag that disagrees with
        // MARKETING_VERSION (FR-10.3), so the tag is the version, minus the
        // "v" the tag form carries.
        let version = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        return (version, release.page)
    }

    /// Compares two `major.minor.patch` versions component by component, as
    /// numbers rather than as text — "0.10.0" is newer than "0.9.0", which no
    /// string comparison will tell you (FR-8.9 numbers each component
    /// independently).
    ///
    /// A component that isn't a number counts as 0, and a missing one counts
    /// as 0 too, so a shorter version compares as if padded. Anything the app
    /// cannot parse therefore reads as "not newer", which is the safe way to
    /// be wrong: it says nothing rather than announcing a release that may not
    /// exist.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

nonisolated enum UpdateCheckError: LocalizedError {
    case badResponse(status: Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status):
            "Couldn't ask GitHub for the latest release (HTTP \(status))."
        }
    }
}
