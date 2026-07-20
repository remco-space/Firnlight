import SwiftUI
import SwiftData
import Observation

/// Drives the AnalysisQueue batch loop from the main actor and republishes
/// its statistics for the UI.
@MainActor
@Observable
final class AnalysisModel {
    private(set) var stats: AnalysisStatistics?
    private(set) var isRunning = false
    private(set) var lastError: String?

    private var queue: AnalysisQueue?
    private var runTask: Task<Void, Never>?

    func refresh(container: ModelContainer) async {
        stats = try? await ensureQueue(container).statistics()
    }

    /// Starts the batch loop if idle and returns the running task, so callers
    /// that must await completion (the startup auto-resync) can, while the
    /// manual button ignores the result. Re-entry while running returns the
    /// in-flight task, so a user click and the auto-resync never double-run.
    @discardableResult
    func start(container: ModelContainer) -> Task<Void, Never> {
        if let runTask, isRunning { return runTask }
        isRunning = true
        lastError = nil
        let queue = ensureQueue(container)

        let task = Task {
            do {
                await queue.beginSession()
                while !Task.isCancelled {
                    guard let processed = try await queue.processNextBatch(), processed > 0 else { break }
                    stats = try await queue.statistics()
                }
            } catch is CancellationError {
                // Stopped by the user; resumable by design.
            } catch {
                lastError = error.localizedDescription
            }
            stats = try? await queue.statistics()
            // Newly accepted photos carry no cached preference score and would
            // otherwise sit unranked at the bottom of the grid until the Duel
            // tab runs; rescore now so ranking is current, then tell views.
            try? await PreferenceRanker(modelContainer: container).prepare()
            RankingClock.shared.bump()
            isRunning = false
        }
        runTask = task
        return task
    }

    /// Stops after the in-flight batch; progress is already saved per batch.
    func stop() {
        runTask?.cancel()
        runTask = nil
    }

    private func ensureQueue(_ container: ModelContainer) -> AnalysisQueue {
        if let queue { return queue }
        let created = AnalysisQueue(modelContainer: container)
        queue = created
        return created
    }
}

/// Vision analysis card: progress, per-reason rejection counts, run controls.
struct AnalysisView: View {
    @Environment(\.modelContext) private var modelContext

    /// Owned by the Library tab so the startup auto-resync can drive the same
    /// loop the manual buttons do.
    let model: AnalysisModel

    /// Changes when a scan completes, triggering a statistics refresh.
    let scanToken: Int?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vision Analysis")
                    .font(.headline)

                if let stats = model.stats {
                    if stats.total == 0 {
                        Text("Scan the library first — analysis runs on the candidates it finds.")
                            .foregroundStyle(.secondary)
                    } else {
                        content(stats)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }

                if let error = model.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
        }
        .task(id: scanToken) {
            await model.refresh(container: modelContext.container)
        }
    }

    @ViewBuilder
    private func content(_ stats: AnalysisStatistics) -> some View {
        ProgressView(value: Double(stats.completed), total: Double(max(stats.total, 1)))
        Text(progressCaption(stats))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            statRow("checkmark.seal", .green, "Wallpaper candidates", stats.accepted)
            statRow("person.2.slash", .secondary, "People", stats.people)
            statRow("doc.viewfinder", .secondary, "Utility images", stats.utility)
            // Plain leaf: the row label carries the negation (no leaf.slash
            // exists, and the arrow variant is the recycling symbol).
            statRow("leaf", .secondary, "Not nature", stats.notNature)
            statRow("icloud.and.arrow.down", .orange, "iCloud (deferred)", stats.skipped)
        }
        .font(.callout.monospacedDigit())

        HStack {
            if model.isRunning {
                Button("Stop") { model.stop() }
                ProgressView()
                    .controlSize(.small)
            } else if stats.pending > 0 {
                Button(stats.analyzed == 0 ? "Analyze \(stats.pending) Photos" : "Resume (\(stats.pending) remaining)") {
                    model.start(container: modelContext.container)
                }
                .buttonStyle(.borderedProminent)
            } else if stats.skipped > 0 {
                Button("Retry \(stats.skipped) iCloud Photos") {
                    model.start(container: modelContext.container)
                }
            } else if stats.horizonPending > 0 {
                Button("Measure \(stats.horizonPending) Horizons") {
                    model.start(container: modelContext.container)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Label("Analysis complete", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
    }

    private func progressCaption(_ stats: AnalysisStatistics) -> String {
        if model.isRunning && stats.pending == 0 && stats.skipped > 0 {
            "\(stats.completed) of \(stats.total) — downloading \(stats.skipped) photos from iCloud…"
        } else if model.isRunning && stats.pending == 0 && stats.horizonPending > 0 {
            "measuring horizons — \(stats.horizonPending) remaining…"
        } else {
            "\(stats.completed) of \(stats.total) candidates analyzed"
        }
    }

    private func statRow(_ symbol: String, _ color: Color, _ label: String, _ value: Int) -> some View {
        GridRow {
            Label(label, systemImage: symbol)
                .foregroundStyle(color == .secondary ? Color.secondary : color)
            Text("\(value)")
                .gridColumnAlignment(.trailing)
        }
    }
}
