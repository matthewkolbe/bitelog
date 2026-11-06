import SwiftUI
import UIKit

/// Logged entries about to become one. The model names what they make
/// together ("Guacamole" from tomato, avocado and onion) as the sheet opens;
/// saying what it is steers it, and typing a name overrides it. Optionally
/// saved as a recipe too.
struct CombineSheet: View {
    let ids: [Int64]
    let model: AppModel
    var done: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var recipe = false
    @State private var naming: Task<Void, Never>?
    @State private var said: String?
    @State private var recorder = Recorder()
    @State private var transcribing = false
    @State private var nameError: String?
    @State private var error: String?

    var body: some View {
        let entries = ids.compactMap { try? model.log.entry($0) }.sorted { $0.createdAt < $1.createdAt }
        let items = entries.flatMap(\.items)
        Form {
            Section {
                HStack {
                    // typing takes over from the model
                    TextField("Name", text: Binding(get: { name }, set: { name = $0; naming?.cancel(); naming = nil }))
                    if naming != nil { ProgressView() }
                }
                if let nameError { Text(nameError).font(.callout).foregroundStyle(.red) }
                VStack(spacing: 6) {
                    HoldToTalk(recorder: recorder, size: 34) { spoken($0, items) }
                        .disabled(transcribing)
                        .frame(maxWidth: .infinity)
                    if recorder.isRecording { RecordingBanner(recorder: recorder, hint: "release to name it") }
                    else if transcribing { HStack { ProgressView(); Text("Transcribing…").foregroundStyle(.secondary) } }
                    else if let said { Text("\u{201C}\(said)\u{201D}").font(.callout).foregroundStyle(.secondary) }
                    else { Text("or hold to say what it is").font(.callout).foregroundStyle(.secondary) }
                }
                Toggle("Also save as a recipe", isOn: $recipe)
            } footer: {
                Text(recipe ? "Say the name next time and it logs as one item, these foods in these amounts."
                            : "One entry, at the time of the first, with every food in it.")
            }
            Section("\(entries.count) entries · \(Int(entries.reduce(0) { $0 + $1.kcal }.rounded())) kcal") {
                ForEach(items) { ItemRow(item: $0) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Combine entries")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { naming?.cancel(); dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Combine") { combine(items) }.disabled(naming != nil || transcribing || recorder.isRecording) }
        }
        .onAppear { if naming == nil && name.isEmpty { suggest(items) } }
    }

    /// Asks the model for a name, replacing the one being asked for.
    private func suggest(_ items: [LogDB.Item]) {
        naming?.cancel()
        nameError = nil
        let said = said
        naming = Task {
            do {
                let n = try await model.logger.nameCombined(items, said: said)
                try Task.checkCancellation()
                name = n
                naming = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                nameError = "Couldn't name it: \(error)"
                naming = nil
            }
        }
    }

    private func spoken(_ url: URL, _ items: [LogDB.Item]) {
        transcribing = true
        Task {
            defer { transcribing = false }
            do {
                let words = try await Transcriber.transcribe(url).text
                try? FileManager.default.removeItem(at: url)
                said = words
                suggest(items)
            } catch {
                nameError = "Couldn't transcribe: \(error)"
            }
        }
    }

    /// The recipe first: if it can't be saved (no name), nothing is combined.
    private func combine(_ items: [LogDB.Item]) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if recipe {
                guard !n.isEmpty else { error = "Name it to save it as a recipe."; return }
                _ = try model.foods.addRecipe(name: n, text: SaveRecipeSheet.text(items), ingredients: items.map {
                    .init(fdcID: $0.fdcID, grams: $0.grams, said: $0.said, adjust: $0.adjust)
                })
            }
            naming?.cancel()
            _ = try model.log.combine(ids, title: n)
            done()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// Where each entry's row is on screen, in window points, for the pinch.
/// A plain class, not observed: rows move on every scroll, and redrawing the
/// list for that would be waste.
final class RowFrames {
    var frames: [Int64: CGRect] = [:]

    func entry(at p: CGPoint) -> Int64? { frames.first { $0.value.contains(p) }?.key }
}

/// Two fingers pinching entries together. It begins only when each finger
/// starts on a different entry and `qualify` accepts the pair; otherwise it
/// fails at once and the list scrolls and taps as usual.
struct EntryPinch: UIGestureRecognizerRepresentable {
    /// The two entries under the fingers -> whether to begin.
    let qualify: (Int64, Int64) -> Bool
    let frames: RowFrames
    /// The fingers' spread, 1 at the start, smaller as they close.
    let changed: (CGFloat) -> Void
    /// Whether the fingers closed far enough to combine.
    let ended: (Bool) -> Void

    static let threshold: CGFloat = 0.6

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let g = UIPinchGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func updateUIGestureRecognizer(_ g: UIPinchGestureRecognizer, context: Context) {
        context.coordinator.shouldBegin = { g in
            guard g.numberOfTouches == 2,
                  let a = frames.entry(at: g.location(ofTouch: 0, in: nil)),
                  let b = frames.entry(at: g.location(ofTouch: 1, in: nil)), a != b
            else { return false }
            return qualify(a, b)
        }
    }

    func handleUIGestureRecognizerAction(_ g: UIPinchGestureRecognizer, context: Context) {
        switch g.state {
        case .changed: changed(g.scale)
        case .ended: ended(g.scale < Self.threshold)
        case .cancelled, .failed: ended(false)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: (UIGestureRecognizer) -> Bool = { _ in false }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { shouldBegin(g) }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
