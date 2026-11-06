import PhotosUI
import SwiftUI
import UIKit

func fmt(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...1))) }

/// A mic button that records while held and hands over the recording on release:
/// a round icon of `size`, with "Hold to talk" under it when `labeled`.
struct HoldToTalk: View {
    let recorder: Recorder
    var size: CGFloat = 44
    var labeled = false
    let onAudio: (URL) -> Void
    @State private var error: String?
    @State private var pressed = false

    var body: some View {
        let live = recorder.isRecording
        VStack(spacing: 2) {
            Image(systemName: live ? "waveform.circle.fill" : "mic.circle.fill")
                .font(.system(size: size))
                .symbolEffect(.pulse, isActive: live)
            if labeled {
                Text(live ? "Release to log it" : "Hold to talk")
                    .font(.caption.weight(.medium)).lineLimit(1).fixedSize()
            }
        }
            .foregroundStyle(live ? Color.red : Color.accentColor)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    Task {
                        do { try await recorder.start() } catch { self.error = String(describing: error) }
                        if !pressed { recorder.cancel() }  // released before the mic started
                    }
                }
                .onEnded { _ in
                    pressed = false
                    if let url = recorder.stop() { onAudio(url) }
                })
            .accessibilityLabel("Hold to talk")
            .accessibilityAddTraits(.isButton)
            .alert("Microphone", isPresented: .constant(error != nil || recorder.state == .denied)) {
                Button("OK") { error = nil; recorder.cancel() }
            } message: {
                Text(error ?? "Bite Log needs the microphone. Allow it in Settings → Bite Log.")
            }
    }
}

/// "Listening… 0:03" while recording.
struct RecordingBanner: View {
    let recorder: Recorder
    var hint = "release to send"

    var body: some View {
        if case .recording(let since) = recorder.state {
            TimelineView(.periodic(from: since, by: 1)) { t in
                let s = Int(t.date.timeIntervalSince(since))
                Label("Listening… \(s / 60):\(String(format: "%02d", s % 60)) — \(hint)", systemImage: "waveform")
                    .font(.callout.weight(.medium)).foregroundStyle(.red)
            }
        }
    }
}

/// Hold to dictate into a text field: the words are added to `text`.
struct Dictation: View {
    let recorder: Recorder
    @Binding var text: String
    var separator = " "
    @State private var status = "or hold to say it"

    var body: some View {
        VStack(spacing: 6) {
            HoldToTalk(recorder: recorder, size: 34) { url in
                status = "Transcribing…"
                Task {
                    do {
                        let words = try await Transcriber.transcribe(url).text
                        try? FileManager.default.removeItem(at: url)
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        text = t.isEmpty ? words : t + separator + words
                        status = "Got it. Hold to say more"
                    } catch {
                        status = "Couldn't transcribe: \(error)"
                    }
                }
            }
            .frame(maxWidth: .infinity)
            if recorder.isRecording { RecordingBanner(recorder: recorder, hint: "release when done") }
            else { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// Picks a photo from the camera (on a phone) or the library, scaled down to
/// `maxSide` pixels as JPEG.
struct PhotoButton<Label: View>: View {
    var maxSide: CGFloat = 1280
    let onPhoto: (Data) -> Void
    @ViewBuilder let label: () -> Label
    @State private var camera = false
    @State private var library: PhotosPickerItem?
    @State private var showLibrary = false

    var body: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { camera = true } label: { SwiftUI.Label("Take a photo", systemImage: "camera") }
            }
            Button { showLibrary = true } label: { SwiftUI.Label("Choose from library", systemImage: "photo") }
        } label: { label() }
        .photosPicker(isPresented: $showLibrary, selection: $library, matching: .images)
        .onChange(of: library) { _, item in
            guard let item else { return }
            library = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
                   let jpeg = shrink(img, maxSide) {
                    onPhoto(jpeg)
                }
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { img in
                camera = false
                if let img, let jpeg = shrink(img, maxSide) { onPhoto(jpeg) }
            }
            .ignoresSafeArea()
        }
    }
}

func shrink(_ img: UIImage, _ maxSide: CGFloat) -> Data? {
    let k = min(1, maxSide / max(img.size.width, img.size.height))
    let size = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        .jpegData(compressionQuality: 0.85)
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}

/// Search the food database and pick one.
struct FoodPicker: View {
    let foods: FoodDB
    let onPick: (FoodDB.Hit) -> Void
    @State private var query = ""
    @State private var hits: [FoodDB.Hit] = []

    var body: some View {
        Section {
            TextField("Search foods, e.g. grapes green raw", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: query) { _, q in
                    hits = q.trimmingCharacters(in: .whitespaces).count < 2 ? [] : ((try? foods.search(q, limit: 20)) ?? [])
                }
            ForEach(hits) { h in
                Button { onPick(h) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.description).foregroundStyle(.primary)
                        Text("\(Int(h.kcal.rounded())) kcal/100 g · P \(fmt(h.proteinG)) F \(fmt(h.fatG)) C \(fmt(h.carbG)) · "
                             + (h.source == "custom" ? "your food" : h.source))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if query.count >= 2 && hits.isEmpty { Text("No matches.").foregroundStyle(.secondary) }
        }
    }
}

/// "Adjusted: fat −30%, carbs +20%"
func adjustText(_ a: Nutrition.Adjust) -> String {
    let names = ["protein_g": "protein", "fat_g": "fat", "carb_g": "carbs", "sugar_g": "sugar", "fiber_g": "fiber",
                 "sat_fat_g": "sat. fat", "sodium_mg": "sodium"]
    return "Adjusted: " + Nutrition.adjustable.compactMap { k in
        a.factors[k].map { f in
            let pct = Int(((f - 1) * 100).rounded())
            return "\(names[k] ?? k) \(pct > 0 ? "+" : pct < 0 ? "−" : "±")\(abs(pct))%"
        }
    }.joined(separator: ", ")
}

/// Daily targets, kept on this phone. 0 = none.
enum Goals {
    static let kcalKey = "goal.kcal"
    static let proteinKey = "goal.protein"
}
