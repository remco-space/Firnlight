import CoreGraphics
import Foundation

/// Every tunable magic number in the app lives here.
/// `nonisolated`: plain constants, readable from any actor (the analysis pipeline runs off-main).
nonisolated enum Thresholds {
    // MARK: The desktop shape (FR-5.1)

    /// Aspect ratio (width / height) of the wallpaper crop the app judges every
    /// photo through: the analysis bitmap is cut to it, the duel cards show it,
    /// and the grid tiles are drawn at it — so what the ranker learns, what the
    /// user compared, and what the grid displays are all the same rectangle.
    ///
    /// Deliberately one fixed shape rather than the running display's. Until
    /// 2026-07-25 this was read live from the main display (`NSScreen.main` in
    /// the duel, `CGDisplayBounds` in analysis), which FR-5.1 no longer allows:
    /// a choice made on an iPhone has to mean exactly what the same choice made
    /// on the Mac means, and both devices score the same photo into one shared
    /// ranking — a per-display crop would have them disagreeing about it. It
    /// also made the Mac disagree with *itself* when the user moved the window
    /// between a 16:9 external display and the built-in one.
    ///
    /// 16:10 because that is the shape of the built-in display on every Mac
    /// Apple currently ships, which is where the wallpaper actually lands; it
    /// was already this app's fallback whenever the display bounds couldn't be
    /// read, and it sits between the 16:9 of most external displays and the
    /// squarer 3:2-ish panels, so neither is badly misjudged.
    static let desktopAspectRatio: CGFloat = 16.0 / 10.0

    // MARK: The interface holding still (FR-8.7)

    /// How long work has to run before the interface admits to waiting on it.
    /// Anything that finishes sooner finishes silently — see the
    /// `shownWhileWaiting` modifier, which every spinner in the app goes
    /// through.
    ///
    /// Almost all of this app's waits are either far under this (a SwiftData
    /// count, a cached thumbnail, recording one duel choice) or far over it (a
    /// library scan, a Vision run, an iCloud download), so the exact value only
    /// has to separate the two populations, not sit at a perceptual boundary.
    /// 0.4 s is Apple's own long-standing spacing for this — it is what
    /// `NSProgressIndicator`'s `usesThreadedAnimation` era shipped as the
    /// delay before a spinner appears, and roughly what UIKit's refresh
    /// controls settle at — and it is comfortably longer than a warm fetch
    /// while still short enough that a real wait never feels unacknowledged.
    ///
    /// Erring low is the cheaper mistake here: showing a spinner slightly too
    /// eagerly costs a flicker, whereas a long silent wait reads as a hang.
    static let noticeableWaitDelay: Duration = .milliseconds(400)

    // MARK: Scan (Phase 2)

    /// Minimum pixel width for a wallpaper candidate. 3264 admits iPhone 5s-era
    /// 8 MP photos (3264×2448) — older photos are rarer, so they get a learned
    /// resolution penalty in the ranker instead of a hard cut.
    static let minimumCandidatePixelWidth = 3264

    /// Pixel width at which the ranker's resolution feature saturates at 1
    /// (extra pixels beyond this add no ranking benefit).
    static let resolutionFullScoreWidth: Float = 6000

    /// Newly inserted records between incremental SwiftData saves during a scan,
    /// so a killed app loses at most one batch of progress.
    static let scanSaveBatchSize = 1000

    /// Assets examined between progress updates and cooperative yields during a scan.
    static let scanProgressStride = 256

    /// Photos per `cloudIdentifierMappings(forLocalIdentifiers:)` call when
    /// resolving device-independent identifiers (FR-9.1).
    ///
    /// PhotoKit's header is blunt about the cost — "This method can be very
    /// expensive so they should be used sparingly for batch lookup of all
    /// needed identifiers" — so the call is made per chunk, never per photo.
    /// It is also synchronous and blocking, which is why it runs off the main
    /// actor. 500 balances the two failure modes: chunks too small pay the
    /// per-call overhead repeatedly, while one unbounded call over a library
    /// this size would block for an unpredictable stretch with no chance to
    /// save partway. Chunking also lets each batch be persisted as it lands,
    /// matching how the scan and analysis already checkpoint.
    static let cloudIdentifierBatchSize = 500

    // MARK: Vision analysis (Phase 3)

    /// Bump when analysis logic changes; records with an older version are re-analyzed.
    /// v3 is required: v2 cut its analysis bitmap to whatever the main display
    /// happened to be, so records analyzed on a 16:9 display measured a
    /// different rectangle than the fixed `desktopAspectRatio` crop the ranker
    /// now assumes — and than the same photo would measure on another device.
    /// v4 is required too: it adds the flawed-photo rejection (FR-3.1), so a
    /// badly blurred or smeared photo accepted under v3 must be re-scored
    /// against `severelyFlawedAestheticsScore` before it can keep counting as
    /// a candidate.
    /// v5 is required too: `ImageAnalyzer` now also runs
    /// `DetectLensSmudgeRequest`, a dedicated obstruction detector the
    /// aesthetics-score gate alone couldn't see — a photo the v4 gate let
    /// through must be re-checked against `lensSmudgeConfidenceThreshold`
    /// before it can keep counting as a candidate. Bumping this alone queues
    /// every already-analyzed record for re-analysis in the background, with
    /// no judgment lost and no user action required (FR-5.2's "must
    /// re-examine what it must" — see `AnalysisQueue.processNextBatch`).
    /// v6 is required too: it tightens the people gate (FR-3.1) after a real
    /// escape — `humanConfidenceThreshold` lowered to catch low-confidence
    /// reclining bodies, and the classification-label people check
    /// (`peopleLabels`) added — so a photo accepted under v5 must be re-judged
    /// before it can keep counting as a candidate.
    /// v7 is required too: it adds the corroborated people check
    /// (`corroboratedPeopleLabelThreshold`) and splits the nature allowlist
    /// into scene and object labels with `outdoor` corroboration
    /// (`natureObjectLabels`), so a photo accepted under v6 — a weakly
    /// detected prominent person, or an indoor still life — must be re-judged
    /// before it can keep counting as a candidate.
    /// v8 is required too: the pipeline now *keeps* what it measures rather
    /// than collapsing it into a gate's yes/no answer, and measures traits it
    /// did not before (person prominence, salient-subject prominence and
    /// centrality, luminance — see `ImageAnalyzer.Outcome`). A photo analyzed
    /// under v7 carries none of them, so it cannot be weighed on equal terms
    /// against one that does (FR-5.2) and must be re-examined.
    ///
    /// This is only the *hand-tuned* half of the version: it catches changes
    /// this app's own code makes to the pipeline, because a developer bumps
    /// it when making one. It cannot catch Apple changing what a Vision
    /// request itself does — a better face or aesthetics model arriving in a
    /// system update, with zero Firnlight code change. `currentAnalysisVersion`
    /// below folds in `VisionRevisionFingerprint` for that half, per FR-5.2's
    /// "notices such changes itself — including ones that arrive with a
    /// system update". Every call site outside this file should keep reading
    /// `currentAnalysisVersion`, never this constant directly.
    /// v9 is required too: it measures six more traits per photo
    /// (colourfulness, foreground coverage and count, animal prominence and text
    /// coverage — see `ImageAnalyzer.Outcome`), which a v8
    /// photo carries none of, so the two cannot be weighed on equal terms
    /// (FR-5.2).
    /// (v10 and v11 corrected how foreground coverage is read off Vision's
    /// instance mask — see `ImageAnalyzer.maskCoverage`; each recorded a
    /// different wrong number, so records carrying either must be
    /// re-measured before being weighed against a v11 one.)
    private static let analysisLogicVersion = 11 // v11: foreground coverage counts covered pixels

    /// What every ranking-affecting query treats as "this build's analysis
    /// generation" — `analysisLogicVersion`, this app's own hand-tuned
    /// pipeline version, combined with `VisionRevisionFingerprint.generation`,
    /// how many times this device has observed the OS's resolved Vision
    /// revisions actually change. Added, not packed or multiplied: either
    /// half advancing — a developer's threshold change, or an OS-shipped
    /// model update — still strictly increases this value and queues
    /// affected records for the same in-place, no-judgment-lost
    /// re-examination (`AnalysisQueue`) that a hand-tuned bump already
    /// triggered, but addition also keeps the untouched case — no Vision
    /// drift ever observed on this device, `generation == 0` — numerically
    /// identical to `analysisLogicVersion` alone, exactly what every record
    /// already carries under the plain-integer scheme that predates
    /// `VisionRevisionFingerprint`. A packed/shifted combination doesn't
    /// have that property (e.g. `analysisLogicVersion << 28` isn't equal to
    /// `analysisLogicVersion`), so it would have made *introducing* this
    /// mechanism look like an examination change to every already-analyzed
    /// record on every device, on the very upgrade meant to fix that class
    /// of bug — the opposite of FR-5.2's "a change that doesn't alter how
    /// photos are examined re-examines nothing: already-current analysis
    /// stays current".
    static var currentAnalysisVersion: Int {
        analysisLogicVersion + VisionRevisionFingerprint.generation
    }

    /// Records analyzed and saved per batch; a killed app loses at most one batch.
    static let analysisBatchSize = 32

    /// Concurrent Vision pipelines within a batch.
    static let analysisConcurrency = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// How long a paused analysis run waits before re-testing the condition
    /// that paused it — device heat, Low Power Mode, or a network the user's
    /// settings don't allow downloads over (FR-3.6, FR-3.7).
    ///
    /// Polling rather than observing `thermalStateDidChangeNotification` /
    /// `NSProcessInfoPowerStateDidChange` / `NWPathMonitor.pathUpdateHandler`:
    /// the loop already has a natural checkpoint between batches, so a poll is
    /// a `guard` there instead of three observers, their registrations, and the
    /// actor hops to deliver them. 20s because none of these conditions clear
    /// quickly — a hot device needs tens of seconds of reduced load to cool,
    /// and Low Power Mode and network policy are user actions — so a shorter
    /// interval would only burn wakeups restating the same answer, while a
    /// longer one would leave the user staring at "waiting" well after the
    /// cause cleared.
    static let analysisPauseRecheckInterval: Duration = .seconds(20)

    /// How long a run waits before trying the photos iCloud hasn't delivered
    /// again (FR-3.4: deferred photos are the app's to retry, never the
    /// user's).
    ///
    /// Deliberately much longer than the pause re-check above, because it
    /// answers a different question. That one asks whether a *condition* has
    /// cleared, which costs a property read; this one asks PhotoKit to attempt
    /// the downloads again, which costs a network round trip per photo and had
    /// just failed. Five minutes is short enough that a download unblocked by
    /// the user opening Photos, or by iCloud finishing something else, is
    /// picked up while they are still at the machine, and long enough that a
    /// photo which will never arrive costs a handful of attempts an hour
    /// rather than a spin.
    static let deferredRetryInterval: Duration = .seconds(300)

    /// How long the app lets library changes settle before catching up with
    /// them (FR-2.6, FR-2.7).
    ///
    /// Photos reports changes as they happen, and a single user action rarely
    /// produces a single notification — importing a batch, an edit propagating
    /// from another device, or the app's own album sync all arrive as a burst.
    /// Catching up is a pass over the library, so the burst is worth
    /// collapsing into one. Two seconds is under the time it takes to notice a
    /// photo missing from the grid, and comfortably longer than the gaps
    /// within a burst.
    static let libraryChangeSettleDelay: Duration = .seconds(2)

    /// How often `LibraryCatchUp` re-reads Photos authorization on its own,
    /// independent of `PhotoLibraryWatcher` (FR-1.8).
    ///
    /// The fast path for noticing a narrowing — full access cut down to a
    /// selection while the app is open — is `photoLibraryDidChange`, and for
    /// most of the app's life that is also the only path: a narrowing made
    /// while backgrounded is caught by the `scenePhase` refresh in
    /// `ContentView` when the app returns to the foreground. Neither covers a
    /// session that stays foregrounded and idle the whole time: no scene-phase
    /// transition fires, and — see the doc comment on
    /// `PhotoLibraryWatcher.photoLibraryDidChange` — Apple documents the
    /// change observer firing for edits to an already-limited selection, not
    /// for the authorization-level transition itself, so relying on it alone
    /// for that case is an assumption this project could not verify. This
    /// timer is the fallback for exactly that gap, not the primary mechanism,
    /// which is why it can afford to be slow: `PHPhotoLibrary
    /// .authorizationStatus(for:)` is a local, synchronous read with no
    /// PhotoKit round trip, so the cost of checking is negligible, but there
    /// is nothing to gain from checking often — a narrowing is a deliberate
    /// trip to Settings, not an event that needs catching within seconds.
    /// Five minutes bounds how long the app could work on a library it no
    /// longer fully sees without ever bothering the user with a busy loop.
    static let authorizationNarrowingRecheckInterval: Duration = .seconds(300)

    /// Square edge, in pixels, that the analysis bitmap is drawn down to
    /// before its mean luminance is taken (`ImageAnalyzer.meanLuminance`).
    ///
    /// The mean of a box-filtered downsample equals the mean of the original,
    /// so this changes the cost of the measurement and not its value; 32 is
    /// small enough that the blit and the 1024-element sum are both noise
    /// beside the Vision requests running either side of it. Not 1×1 — which
    /// would compute the same number in principle — because a single-pixel
    /// destination leans entirely on the interpolator averaging every source
    /// pixel, which Core Graphics documents no guarantee about.
    static let luminanceSampleSize = 32

    /// Long-edge size of the analysis bitmap requested from PHImageManager. Never analyze full-res.
    static let analysisPixelSize = 1024

    /// Minimum DetectHumanRectanglesRequest confidence that counts as a person.
    ///
    /// Tuning history: shipped at 0.3; lowered to 0.2 on 2026-08-14 after a
    /// real escape (IMG_0259) — a reclining sunbather filling a third of the
    /// frame came back at confidence 0.27, one hundredth under the old floor.
    /// Vision's confidence drops on reclining or partially occluded bodies,
    /// and this gate only fires together with the prominence test
    /// (`personProminenceHeight`), so a lower floor cannot reject the distant
    /// figures FR-3.1 admits — it only tightens the call on rectangles already
    /// big enough to be the subject.
    static let humanConfidenceThreshold: Float = 0.2

    /// Classification labels that read as people being the subject of the
    /// photo, checked against the same `ClassifyImageRequest` results the
    /// nature gate uses (no extra Vision pass). This is the third, independent
    /// people signal (FR-3.1): the rectangle detectors measure geometry, but a
    /// person can defeat both — face too small when reclining, body confidence
    /// low in unusual poses — while the whole-image classifier still calls the
    /// scene "people" outright (0.85 on the escape that motivated this gate).
    /// Every entry verified against `ClassifyImageRequest().supportedIdentifiers`.
    static let peopleLabels: Set<String> = ["people", "adult", "child", "baby", "crowd"]

    /// Minimum confidence on any `peopleLabels` entry that rejects the photo.
    /// Higher than `natureConfidenceThreshold` on purpose: FR-3.1 admits
    /// distant figures in a cityscape, and a scene-dominating person should
    /// classify strongly (the motivating escape scored 0.85) while incidental
    /// figures should not. One real data point so far — tune from real library
    /// data via the ImageAnalyzer debug log, like `natureLabels`.
    static let peopleLabelConfidenceThreshold: Float = 0.75

    /// Minimum `peopleLabels` confidence that rejects when *corroborated* by a
    /// human rectangle at least `personProminenceHeight` tall — the fourth
    /// people signal (FR-3.1), for the photo that defeats every standalone
    /// gate at once. The motivating escape (IMG_0232, a swimmer mid-frame):
    /// body rectangle 16% of frame height at confidence 0.18, `people` label
    /// 0.46 — each under its standalone bar, together unambiguous. Distant
    /// figures FR-3.1 admits stay safe: their rectangles fail the prominence
    /// test, so no label confidence alone can trip this.
    static let corroboratedPeopleLabelThreshold: Float = 0.4

    /// Rectangle-confidence floor inside the corroborated check above — low on
    /// purpose (the label carries the certainty; the rectangle only has to
    /// locate a prominent figure), non-zero so a pure-noise detection cannot
    /// combine with an incidental label.
    static let corroboratedHumanConfidenceThreshold: Float = 0.1

    /// A face (or confident human rectangle) taller than this fraction of the
    /// analysis frame height reads as a foreground portrait subject, not a
    /// distant passer-by, and rejects the photo. Shared between faces and human
    /// rectangles: a body this tall is scenery-dominating either way.
    /// (FR-3.1 revision 2026-07-20: cityscapes admit distant people; only a lot
    /// of people, or a prominent one, reject.)
    /// CGFloat to match Vision's normalized bounding-box height.
    static let personProminenceHeight: CGFloat = 0.08

    /// Face count at or above which the frame reads as a crowd and rejects,
    /// regardless of how small any individual face is.
    static let crowdFaceCount = 6

    /// Minimum classification confidence for a label to count toward the nature check.
    static let natureConfidenceThreshold: Float = 0.4

    /// `CalculateImageAestheticsScoresRequest.overallScore` (range -1…1; Apple
    /// documents it as reflecting how well taken the image is, blur and
    /// exposure among its factors) below which a photo is rejected as flawed
    /// — FR-3.1's "finger over the lens, a badly blurred or smeared frame" —
    /// rather than merely ranked lower. Set well under the neutral midpoint
    /// (0) so an ordinarily mediocre but intact photo is never caught: this
    /// gate is for photos too damaged to use "however good the scene," not a
    /// second aesthetics cutoff. This is one of two independent flaw gates —
    /// see `lensSmudgeConfidenceThreshold` for the other — since aesthetics
    /// folds in technical quality generally but isn't a dedicated obstruction
    /// detector; unverified against real flawed photos, so tune from real
    /// library data the same way `natureLabels` is tuned, via the
    /// ImageAnalyzer debug log.
    static let severelyFlawedAestheticsScore: Float = -0.5

    /// `SmudgeObservation.confidence` (0…1) from `DetectLensSmudgeRequest`
    /// (macOS/iOS 26+) at or above which a photo is rejected as flawed — the
    /// dedicated detector for FR-3.1's "a finger over the lens" specifically,
    /// independent of `severelyFlawedAestheticsScore`: a smudge can sit in a
    /// corner of an otherwise well-exposed, sharp frame and never pull the
    /// overall aesthetics score low enough to trip that gate alone. 0.7 errs
    /// toward the same side `severelyFlawedAestheticsScore` does — reject only
    /// what the model is confident about, since a false rejection silently
    /// removes a candidate the user never gets a chance to see and choose in a
    /// duel, while a false negative is merely ranked on its other merits, same
    /// as any other request in this pipeline. Unverified against real smudged
    /// photos (no such photos in hand while this shipped); tune from real
    /// library data via the ImageAnalyzer debug log.
    static let lensSmudgeConfidenceThreshold: Float = 0.7

    // MARK: Candidate grid (Phase 4)

    /// Feature-print distance below which two photos count as near-duplicates
    /// (greedy pass over the ranked list; L2 distance on the raw print vectors).
    /// 0.35 let same-subject re-takes through on real library data; raised to 0.5.
    static let nearDuplicateDistance: Float = 0.5

    /// Maximum candidates shown in the grid; bounds the dedupe cost.
    static let gridMaxCandidates = 600

    /// Long-edge pixel size for grid thumbnails.
    static let gridThumbnailPixelSize = 320

    /// Added to aestheticsScore (range -1…1) when ranking: Photos favorites are
    /// a prior for "liked" until the preference ranker takes over.
    static let favoriteRankBoost: Float = 0.3

    // MARK: Duel + preference ranker (Phase 5)

    /// Bump when the ranker's algorithm changes (features, normalization,
    /// seeding, learning rate semantics). A mismatch with the stored weights
    /// file triggers an automatic rebuild: re-seed from current favorites,
    /// replay all choices (and, from v5, bad verdicts), re-rank everything.
    /// v5 is required, not optional: a bad verdict recorded before this
    /// version shipped was never applied to the weights that existed at the
    /// time, so only a full rebuild folds that backlog in — no incremental
    /// catch-up is possible (FR-5.3).
    /// v6 is required too: it adds the `time`/`location` features (FR-5.2's
    /// "when and where"), and `Weights` gained the two fields that carry
    /// their learned coefficients — a v5 weights file has no opinion about
    /// either, so only a full rebuild (re-seed + full choice/verdict replay)
    /// folds them in, same reasoning as v5's bad-verdict backlog.
    /// v7 is required too: v6's `time`/`location` were normalized against the
    /// current candidate set (oldest/newest dated photo, distance from the
    /// location centroid), which meant an ordinary library scan could shift
    /// those denominators and silently rescale every already-trained
    /// `weights.time`/`weights.location` coefficient's meaning — a v6 weights
    /// file may have been fit to a scale that no longer matches what
    /// `PreferenceRanker.loadEntries()` now computes, so it must be discarded
    /// and rebuilt rather than reused. v7 replaces both with fixed,
    /// library-independent scales (`PreferenceRanker.seasonFraction`,
    /// latitude ÷ 90) that never move under a growing library — see
    /// `PreferenceRanker`'s type doc comment.
    /// v11 is required too: it adds the three place-scale weight buckets
    /// below (FR-5.14) — a v10 weights file has no opinion about any of
    /// them, so only a full rebuild (re-seed + full choice/verdict replay)
    /// folds them in, the same reasoning every earlier trait addition here
    /// gives.
    static let rankerAlgorithmVersion = 11 // v11: three-scale place hierarchy (FR-5.14)

    // MARK: Place hierarchy (FR-5.13, FR-5.14)

    /// How many learned weight buckets each scale of `PlaceHierarchy` gets in
    /// `PreferenceRanker.Weights.place` — one photo activates exactly one
    /// bucket per scale (a hash of its grid cell, or of the resolved place
    /// name once `PlaceNameLookup` has one), and SGD learns each bucket's
    /// weight from duels exactly like every other trait (FR-5.2).
    ///
    /// Fewer buckets at coarser scales, matching what each scale is *for*:
    /// a library plausibly touches dozens of towns but far fewer countries,
    /// and a smaller table means more photos share a bucket, which is what
    /// lets a heavily-judged scale's weight dominate a barely-judged finer
    /// one as it decays toward zero between reinforcements (FR-5.11's "leans
    /// on the larger places around it" falls out of `rankerWeightDecay`
    /// already applying to every weight on every SGD step, not out of any
    /// bespoke smoothing here). Unverified against a real library's spread
    /// of distinct places; tune by watching how many distinct fine keys a
    /// real library resolves to, the same way every other geometric or
    /// count-based threshold here is tuned.
    static let placeFineBucketCount = 48
    static let placeMediumBucketCount = 24
    static let placeCoarseBucketCount = 12

    /// How long `PlaceNameLookup` waits after successfully resolving one
    /// cell before asking about the next — FR-5.13's "at the pace the
    /// source permits". Apple documents no rate limit for
    /// `MKReverseGeocodingRequest`, so this is simply a courteous, arbitrary
    /// pace for a background enrichment nobody is waiting on, not a measured
    /// limit — a duel or an album sync never blocks on it either way.
    static let placeNameLookupPace: Duration = .seconds(2)

    /// How long `PlaceNameLookup` waits before trying again after a call
    /// that made no progress — no network (FR-3.7), or nothing left to look
    /// up. Long relative to `placeNameLookupPace` for the same reason
    /// `deferredRetryInterval` is long relative to `analysisPauseRecheckInterval`:
    /// re-testing a condition that rarely changes moment to moment should
    /// cost the idle loop almost nothing.
    static let placeNameLookupIdleInterval: Duration = .seconds(60)

    /// How many resolved cells `LibraryCatchUp`'s lookup loop coalesces
    /// before it reloads the ranker and bumps `RankingClock` — the same
    /// batch-or-idle debounce shape `preferenceCacheFlushBatchSize` already
    /// uses for duel choices, applied here for the same reason (FR-8.2): a
    /// library with hundreds of unresolved places would otherwise cost a
    /// full-pool reload (`FeatureStore.albumCandidates`, `suggestedAlbumSize`)
    /// every `placeNameLookupPace`, for a background enrichment nobody
    /// pressed a button for. A trailing partial batch is still flushed as
    /// soon as the loop goes idle (nothing pending, or waiting on the
    /// network) rather than held forever, the same "idle bound" half of that
    /// existing debounce.
    static let placeNameLookupBatchSize = 10

    /// Distinct foreground objects at which the ranker's `subjectCount` trait
    /// saturates at 1.
    ///
    /// The trait has to separate "one clean subject" from "a scattering of
    /// them"; past a handful the frame reads as busy regardless of whether
    /// Vision resolved nine objects or nineteen. 8 puts the saturation point
    /// past every composition where the exact count still changes how the
    /// picture reads.
    static let subjectCountFullScale = 8

    /// Aspect-ratio mismatch, as a factor away from `desktopAspectRatio`, at
    /// which the ranker's `aspectSkew` trait saturates at ±1.
    ///
    /// One octave: a 32:10 panorama sits at +1 and an 8:10 portrait at −1,
    /// with 16:10 itself at 0. Everything a phone or camera produces in
    /// ordinary use falls inside that, and the shapes beyond it are already
    /// so far from the wallpaper rectangle that further distinction buys the
    /// ranking nothing.
    static let aspectSkewFullScale: Float = 2

    /// Metres above sea level at which the ranker's `altitude` trait
    /// saturates at 1.
    ///
    /// 3000 m puts the top of the scale around the height of an alpine pass
    /// or a mid-range summit — above it, "high" stops being a distinction
    /// that changes how a landscape reads. The scale is signed, so the few
    /// places below sea level map to a small negative rather than clamping
    /// with everything at the shore.
    static let altitudeFullScaleMetres: Double = 3000

    /// Calendar year the ranker's `captureEra` trait treats as its zero, and
    /// the half-span that reaches ±1 (so 1975…2075).
    ///
    /// Fixed years, never "years ago": an age-based scale would move every
    /// day and quietly re-rank a library with no new judgment behind it. A
    /// span this wide costs the trait nothing in practice — a library covers
    /// a couple of decades, which is a comfortable fraction of the scale —
    /// and it will not need revisiting within the app's life.
    static let captureEraCentreYear: Float = 2025
    static let captureEraHalfSpanYears: Float = 50

    /// Degrees of solar elevation over which the `sunElevation` trait's
    /// compression is centred — the scale on which sunlight changes near the
    /// horizon.
    ///
    /// Golden hour is conventionally the sun between roughly 0° and 6°, and
    /// blue hour the few degrees below 0°, so a scale constant of 6° puts the
    /// whole of that interesting band inside the first unit of the
    /// transformed scale while the flat 40°-to-90° stretch compresses into
    /// the last. See `PreferenceRanker.sunElevationBasis`.
    static let sunElevationHorizonScaleDegrees: Double = 6

    /// SGD learning rate for the online Bradley–Terry ranker.
    static let rankerLearningRate: Float = 0.5

    /// L2 weight-decay factor applied before each SGD step; bounds weight growth
    /// so raw scores stay in a sane range and one duel can't swing the ranking.
    static let rankerWeightDecay: Float = 0.01

    /// Fixed seed for the deterministic RNG used when seeding fresh weights from
    /// favorites, so an identical choice history rebuilds the same ranking.
    static let rankerSeedRNG: UInt64 = 0x616C70656E676C6F // "alpenglo"

    /// Without verdict calibration, duels draw from this top fraction of all
    /// candidates — wide, so "both bad" verdicts can find the quality floor.
    static let duelPoolFraction: Float = 0.75

    /// Duel pool never shrinks below this many photos.
    static let duelPoolMinimum = 200

    /// With calibration, the duel pool is everything scoring above
    /// (verdict bar − this margin): export candidates plus a probing band below.
    /// Raw-score units: the sigmoid slope at the center is ¼, so this 0.5 raw
    /// margin ≈ the old 0.1 sigmoid margin.
    static let duelPoolScoreMargin: Float = 0.5

    /// Random pair samples per duel; the closest-scored valid pair wins (uncertainty sampling).
    static let duelPairSamples = 32

    /// Pseudo-choices per Photos favorite when seeding fresh ranker weights.
    static let favoriteSeedOpponents = 3

    /// Cap on total favorite pseudo-choices during seeding.
    static let favoriteSeedMaxPairs = 300

    /// Long-edge pixel size for duel images.
    static let duelImagePixelSize = 1024

    // MARK: Preference-score cache flush (Phase 5) — responsiveness (FR-8.2)

    /// A single duel choice nudges every candidate's raw score by a tiny amount
    /// (one SGD step + weight decay touches every weight). Rewriting the whole
    /// `PhotoRecord.preferenceScore` cache and saving on *every* choice held the
    /// SQLite write lock long enough to stall the main context's reads and
    /// beachball the UI (FR-8.2). Instead the cache is flushed off the hot path
    /// once a burst of choices settles — whichever of the two bounds below hits
    /// first. This one caps how many rapid-fire choices coalesce into one write,
    /// so the grid never lags further than a handful of clicks behind (FR-4.5).
    static let preferenceCacheFlushBatchSize = 8

    /// The other flush bound: quiet time after the last choice before the cache
    /// is written and the ranked views (grid re-order, export preview) refresh.
    /// Long enough to coalesce a fast clicking streak into one write, short
    /// enough that the grid catches up almost immediately once the user pauses,
    /// keeping the re-ordering "live" (FR-4.5).
    static let preferenceCacheFlushIdleInterval: Duration = .seconds(1.5)

    /// Minimum raw-score change that dirties a cached `preferenceScore`. Below
    /// this the shift is float noise — sub-visible after the sigmoid and
    /// rank-order-neutral — so skipping the write stops one SGD step from
    /// dirtying (and rewriting) every row, which is exactly the write
    /// amplification the debounce exists to avoid. Accumulated drift still
    /// crosses it within a few choices and gets written, and prepare() rewrites
    /// the whole cache on launch, so the cache always reconverges regardless.
    static let preferenceCacheEpsilon: Float = 0.001

    // MARK: Horizon prior

    /// Tilt (degrees) at which the ranker's levelness feature bottoms out at 0.
    static let horizonMaxTiltDegrees: Float = 45

    // MARK: Wallpaper album (Phase 6)

    /// Name of the Photos album the app keeps in sync with top candidates.
    static let wallpaperAlbumName = "Firnlight"

    /// Placeholder top-N shown only before the first real suggestion and pool
    /// size have arrived (`ExportModel.isReady` is false) — never a fallback
    /// suggestion value itself. FR-6.4 forbids the estimate a floor or
    /// default of its own; this is UI scaffolding for the moment before there
    /// is an estimate to show at all.
    static let defaultWallpaperCount = 50

    /// Minimum normalized score spread required to trust the knee detection.
    static let albumSuggestionMinimumSpread: Float = 0.05

    /// How far a verdict class's zone reaches beyond its mean, in standard
    /// deviations of that class's own scores: the bad zone ends at
    /// mean(bad) + this × σ(bad), the great zone starts at mean(great) −
    /// this × σ(great) (`FeatureStore.classBoundary`).
    ///
    /// Mean-and-spread rather than the class extreme, because FR-6.4's
    /// "scores like the photos the user called bad/great" describes
    /// resemblance to the class, and an extreme lets one judgment overrule
    /// the rest — observed on real library data (2026-08-14, 56 great / 26
    /// bad verdicts): a single "Both Are Bad" on a photo the ranker scored
    /// near the very top pushed `bad.max()` to +0.05 and the suggestion to 1,
    /// while the bad class's bulk sat around −0.83 ± 0.26. A mean±σ boundary
    /// also makes every judgment shift the estimate a little, which FR-6.4's
    /// "neither kind of judgment is ever without effect" demands — under the
    /// extreme statistic, every non-extreme judgment had none.
    ///
    /// 1.3 ≈ the 90th percentile of a roughly normal class: the zone covers
    /// the class's bulk and tolerates its stragglers without letting them
    /// rule. On the same real data it puts the bad ceiling near −0.5 —
    /// about 640 of 7 153 candidates above it, in the range the user's own
    /// estimate of the library ("roughly 400 album-worthy") points at, where
    /// the extreme statistic gave 1–14. Tune against the Album suggestion
    /// log line.
    static let verdictClassSpread: Float = 1.3

    /// "Both bad" verdicts needed before they calibrate the duel pool's
    /// quality bar (`PreferenceRanker.verdictBar`) — below that, the pool
    /// falls back to a plain top fraction. Unrelated to the album-size
    /// suggestion (FR-6.4), which a single verdict of either kind already
    /// shapes with no minimum count.
    static let albumCalibrationMinimumBadVerdicts = 2

    /// Album ordering maximizes the minimum feature-print distance to this
    /// many previously placed photos, so consecutive wallpapers look different.
    static let albumDiversityWindow = 5

    /// How close two candidates' raw scores must be before FR-6.1 will let a
    /// more-varied one displace a more-similar-to-what's-already-chosen one
    /// in the album's *membership* — distinct from `albumDiversityWindow`,
    /// which only reorders an already-decided membership for playback
    /// (FR-6.2). This is what makes "a photo the user's taste clearly rates
    /// higher never gives way to variety" concrete: outside this margin, a
    /// higher-scored candidate is never skipped, however similar it is to
    /// what's already in; inside it, `FeatureStore.selectDiverseMix` may
    /// prefer whichever candidate in the tied band repeats the fewest
    /// already-chosen place/season/visual axes.
    ///
    /// Raw-score units, same scale `duelPoolScoreMargin` already uses: the
    /// sigmoid's slope at the centre is ¼, so a gap of this size corresponds
    /// to roughly a 55/45 split in which photo a duel would favour — close
    /// enough to read as "nearly alike" rather than a real preference.
    /// Unverified against real library data; tune the same way
    /// `verdictClassSpread` was, by watching what real near-tied stretches
    /// of a real ranking actually contain.
    static let albumMixScoreTolerance: Float = 0.2

    /// Feature-print distance below which two already-deduplicated
    /// candidates still count as "similar scene or mood" for FR-6.1's mix —
    /// looser than `nearDuplicateDistance`, which has already removed actual
    /// re-takes of the same vista before this stage ever sees the pool.
    /// This one is about two *different* photos that nonetheless read alike
    /// (the same kind of sunset, the same style of forest path), which is
    /// exactly the "mood" FR-6.1 names alongside place and season.
    /// Unverified against real library data — a wider band than
    /// `nearDuplicateDistance`'s 0.5 by construction, since it has to catch
    /// more than exact re-takes; tune the same way that constant was, by
    /// watching what a real ranked pool clusters into.
    static let albumMixVisualSimilarityDistance: Float = 0.8

    // MARK: The album-size scale (FR-6.3)

    /// The smallest album the size slider offers — FR-6.3's "a handful of
    /// photos". Ten is roughly a fortnight of daily desktops, below which the
    /// album stops being a rotation at all; and the difference between three
    /// and four is not worth track that has to reach the other end of a
    /// library measured in thousands. The number field is held to the same
    /// floor, so the two halves of the control cannot disagree about what the
    /// smallest album is.
    static let minimumWallpaperCount = 10

    /// Leading digits of the round counts the slider marks: 10, 20, 50, 100,
    /// 200, 500 … A 1-2-5 ladder is the standard round-number series for a
    /// logarithmic axis, because its steps are near-evenly spaced in log space
    /// (×2, ×2.5, ×2) — the marks land at even intervals along the track while
    /// every label stays a number a person would say out loud. A 1-3 ladder
    /// spaces more evenly still and reads worse; plain decades leave a gap of
    /// a whole ×10 between marks, which is what `albumSizeMarkLimit` falls
    /// back to only when the ladder gets crowded.
    static let albumSizeMarkMantissas = [1, 2, 5]

    /// How many round marks the slider may carry before it thins them to plain
    /// decades. FR-6.3 asks for "a few labeled marks"; past six, their labels
    /// start to touch in a narrow window, and a mark whose label is unreadable
    /// is worse than no mark.
    static let albumSizeMarkLimit = 6

    /// Distance from the end of a slider's track to the centre of its thumb
    /// when the thumb is parked there — the inset the app has to reproduce
    /// both to line its own mark labels up with the ticks the system draws
    /// (iPhone and iPad) and to know where any label will land when deciding
    /// which ones fit (FR-8.11, both platforms).
    ///
    /// There is no API that reports it, so it is measured. iOS 27 simulator: a
    /// 340pt track put its 0.0 and 1.0 ticks 17.5pt in from each end, which is
    /// half the width of the thumb; verified by putting a label row under a
    /// ticked slider and checking every label sat under its dot. macOS 27: the
    /// same measurement off the Export card's own slider gives about 6pt, its
    /// thumb being much the smaller. If a future thumb changes size these move
    /// with it, and the symptom is labels drifting off their marks toward the
    /// ends.
    static let sliderTrackInset: CGFloat = {
        #if os(macOS)
        6
        #else
        17.5
        #endif
    }()

    /// How much one VoiceOver or Full Keyboard Access step changes the album
    /// size, as a multiple of the current count.
    ///
    /// A tenth, matching the proportional nudge FR-6.3 asks of the thumb: the
    /// same press moves 20 to 22 and 2,000 to 2,200. A slider left to its own
    /// devices steps by a tenth of its *range*, which on a logarithmic scale
    /// is nearly a doubling — eleven or so counts reachable across a whole
    /// library, which is no way to pick a number.
    static let albumSizeAssistiveStep = 1.1

    /// Diameter of the dots drawn under the size slider's track on iPhone and
    /// iPad, where the app draws its own scale (see `ExportView.markScale`).
    ///
    /// Matched by eye to the ticks the system used to draw there, so the scale
    /// reads the same as before the ticks had to go: small enough to be a mark
    /// rather than a control, large enough to survive a Retina downscale.
    static let albumSizeMarkDotSize: CGFloat = 3

    /// Clear space demanded between two mark labels on the size slider before
    /// they count as fitting side by side (FR-8.11).
    ///
    /// Six points is about the width of a space at these sizes: enough that
    /// two labels read as two, and small enough that it costs no mark that
    /// would genuinely have fitted. It is deliberately a length and not a
    /// fraction of the track — the mistake that let "Suggested" print over
    /// "1,000" on the iPad was measuring a collision in units that stretch
    /// while the text does not.
    static let albumSizeLabelGap: CGFloat = 6

    /// How close to the suggestion's mark the thumb has to come, **in points
    /// on screen**, before the mark catches it (FR-6.3's one exception; see
    /// `AlbumSizeScale.detented`).
    ///
    /// A distance, not a share of the track, because what has to come within
    /// reach is a fingertip or a pointer and neither grows with the window: a
    /// share that catches nicely on a wide Mac is a couple of points on a
    /// narrow iPhone, which no finger can hit.
    ///
    /// 12pt is a little under half Apple's 44pt minimum touch target — close
    /// enough that a finger aiming at the mark lands inside it, and far enough
    /// from the neighbouring round marks (which the scale never places nearer
    /// than the width of their own labels) that nothing else is swallowed.
    /// Erring large is the cheaper mistake: the exact count either side is a
    /// keystroke away in the number field, while a catch too small to feel
    /// leaves FR-6.4's "adopting it is moving the thumb onto the mark"
    /// impossible to actually do.
    static let albumSizeDetentReach: CGFloat = 12


    /// A photo is "nature" if any label in this allowlist meets the confidence
    /// threshold. These are *scene* labels — places, not things — so any one
    /// of them is evidence of a scene on its own.
    /// Every entry is verified to exist in ClassifyImageRequest().supportedIdentifiers
    /// (1303 identifiers on this SDK; all lowercase, multi-word joined by underscores —
    /// e.g. "sunset_sunrise", NOT "sunset"/"sunrise").
    /// Tune from real library data via the ImageAnalyzer debug log of rejected labels.
    /// If false positives appear, the broad umbrella labels ("land", "water_body")
    /// are the first candidates to remove.
    static let natureSceneLabels: Set<String> = [
        // Landforms
        "mountain", "hill", "cliff", "canyon", "cave", "desert",
        "sand_dune", "sand", "rocks", "island", "volcano", "lava",
        "geyser", "land",

        // Ice & snow
        "glacier", "iceberg", "ice", "snow",

        // Water features
        "ocean", "lake", "river", "creek", "waterfall", "water",
        "water_body", "waterways", "wetland", "shore", "beach",
        "coral_reef", "underwater",

        // Sky, celestial & weather
        "sky", "blue_sky", "cloudy", "night_sky", "aurora", "rainbow",
        "sun", "moon", "celestial_body", "celestial_body_other",
        "sunset_sunrise", "storm", "thunderstorm", "lightning",
        "blizzard", "haze",

        // Forest
        "forest", "jungle",

        // Scenic cultivated landscapes & trails
        "vineyard", "orchard", "rice_field", "trail",

        // Cityscapes & landmarks (FR-3.1 revision 2026-07-20)
        "cityscape", "skyscraper", "bridge", "castle", "lighthouse",
        "harbour", "monument", "belltower", "clock_tower",
    ]

    /// Nature labels that name a *thing*, not a place — a tulip, a potted
    /// plant, a tree — and so admit a photo only when the classifier also saw
    /// `outdoor` at `outdoorCorroborationThreshold` or better. A vase of
    /// tulips on a dining table classifies exactly like a garden bed
    /// (plant/flower/tulip all ≥ 0.6 on the escape that split this list out,
    /// IMG_0962) — the scene-versus-still-life difference lives entirely in
    /// the `outdoor` label, which fired at 0.86–0.90 on real scenes and under
    /// 0.1 on the vase. Splitting rather than gating everything on `outdoor`
    /// keeps the risk contained: underwater or night-sky scenes, where
    /// `outdoor` may plausibly stay quiet, all admit through scene labels and
    /// never pay this test. Same identifier-verification and tuning rules as
    /// `natureSceneLabels`.
    static let natureObjectLabels: Set<String> = [
        // Trees & vegetation (houseplants and cut branches are the indoor risk)
        "tree", "evergreen", "palm_tree", "maple_tree", "oak_tree",
        "eucalyptus_tree", "sequoia", "willow", "mangrove", "foliage",
        "branch", "vegetation", "plant", "grass", "moss", "ferns",
        "shrub", "ivy", "clover", "cactus", "blossom", "wheat",

        // Flowers (bouquets and vases are the indoor risk)
        "flower", "rose", "tulip", "sunflower", "orchid", "lily",
        "daisy", "daffodil", "dahlia", "dandelion", "carnation",
        "chrysanthemum", "cornflower", "begonia", "petunia",
        "marigold", "snapdragon",
    ]

    /// Minimum `outdoor` classification confidence that lets a
    /// `natureObjectLabels` match count as a scene. Below the general 0.4
    /// label bar on purpose: a flower macro with a blurred background may
    /// classify `outdoor` only weakly, and a false rejection silently removes
    /// a candidate the user never sees, while everything indoors observed so
    /// far sits under 0.1. One real still life and two real scenes as data
    /// points — tune from real library data via the ImageAnalyzer debug log.
    static let outdoorCorroborationThreshold: Float = 0.25

    // MARK: Touch targets (HIG, FR-8.1)

    /// Apple's Human Interface Guidelines minimum tappable size on iOS/iPadOS
    /// ("Layout" — hit targets should measure at least 44x44pt). FR-8.1 defers
    /// the app's whole native-feel checklist to the HIG, so the small
    /// glass-circle controls overlaid on thumbnails (`CandidateGridView`'s
    /// verdict toggles and iOS actions menu) size their *invisible* touch
    /// area to this constant on iOS, independent of how small their visible
    /// glass glyph stays — see those call sites for why the two are kept
    /// separate rather than drawing the glass itself this large.
    static let minimumTouchTarget: CGFloat = 44
}
