import SwiftUI

/// The Chingu chat overlay UI — a wide, compact bar below the notch. Hosted inside the
/// non-activating panel; also runnable standalone in a window for development.
struct ChatView: View {
    @ObservedObject var model: ChatViewModel
    @StateObject private var voice: VoiceController
    @StateObject private var pointer: PointingController
    @State private var isHovered = false

    init(model: ChatViewModel) {
        self.model = model
        _voice = StateObject(wrappedValue: VoiceController(model: model))
        _pointer = StateObject(wrappedValue: PointingController(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thread
            composer
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 720)
        .frame(minHeight: 130, maxHeight: 280)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(isHovered ? 0.14 : 0.06), lineWidth: 1)
        )
        .opacity(isHovered ? 1 : 0.12)
        .animation(.easeInOut(duration: 0.22), value: isHovered)
        .onContinuousHover { phase in
            switch phase {
            case .active:   isHovered = true
            case .ended:    isHovered = false
            }
        }
    }

    // MARK: Background

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.72))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.55)
        }
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        MessageLine(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.bottom, 4)
            }
            .onChange(of: model.messages) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let missing = Secrets.missingRequiredKeys
        HStack(alignment: .top, spacing: 10) {
            globeIcon
            VStack(alignment: .leading, spacing: 4) {
                if missing.isEmpty {
                    Text("Ask anything — I can see your screen and search the web.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.92))
                } else {
                    Text("Setup needed")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(Secrets.setupMessage(for: missing))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let notice = model.captureNotice {
                captureBanner(notice)
            }
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if model.input.isEmpty {
                        placeholderHint
                    }
                    TextField("", text: $model.input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .lineLimit(1...3)
                        .onSubmit(model.send)
                        .submitLabel(.send)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.1))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )

                actionButton
            }

            if let note = voiceNote {
                Text(note.text)
                    .font(.caption2)
                    .foregroundStyle(note.isError ? Color.orange : Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            }
        }
        .padding(.top, 8)
    }

    /// Matches the mock: "Type or hold [⌘] to speak" with a keycap-styled command glyph.
    private var placeholderHint: some View {
        HStack(spacing: 4) {
            Text("Type or hold")
                .foregroundStyle(.white.opacity(0.38))
            KeycapLabel(symbol: "⌘")
            Text("K to speak")
                .foregroundStyle(.white.opacity(0.38))
        }
        .font(.system(size: 14))
        .allowsHitTesting(false)
        .padding(.leading, 2)
    }

    /// Mic / stop — tap to listen, tap while speaking to interrupt, or use ⌃⌥⌘K.
    private var actionButton: some View {
        Button(action: actionButtonTapped) {
            Image(systemName: actionSymbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(actionTint.opacity(0.22)))
                .foregroundStyle(actionTint)
        }
        .buttonStyle(.plain)
        .help(actionHelp)
        .disabled(actionDisabled)
    }

    private var actionSymbol: String {
        switch voice.state {
        case .speaking:     return "stop.fill"
        case .listening:    return "stop.fill"
        case .transcribing: return "ellipsis"
        case .idle:         return "mic.fill"
        }
    }

    private var actionTint: Color {
        switch voice.state {
        case .speaking, .listening: return .red
        case .transcribing:         return .white.opacity(0.5)
        case .idle:                 return model.isResponding ? .white.opacity(0.35) : .white.opacity(0.85)
        }
    }

    private var actionDisabled: Bool {
        voice.state == .transcribing || (voice.state == .idle && model.isResponding)
    }

    private var actionHelp: String {
        voice.state == .speaking ? "Stop speaking" : "Ask by voice (⌃⌥⌘K)"
    }

    private func actionButtonTapped() {
        if voice.state == .speaking {
            voice.interruptSpeech()
        } else {
            voice.toggleMic()
        }
    }

    private var voiceNote: (text: String, isError: Bool)? {
        if let error = voice.errorMessage { return (error, true) }
        switch voice.state {
        case .listening:    return ("Listening…", false)
        case .transcribing: return ("Transcribing…", false)
        case .speaking:     return ("Speaking…", false)
        case .idle:         return nil
        }
    }

    private func captureBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var globeIcon: some View {
        Image(systemName: "globe.americas.fill")
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.blue.opacity(0.85)))
    }

    private static let bottomAnchor = "chingu.bottom.anchor"
}

// MARK: - Message line (flat text, no bubbles)

private struct MessageLine: View {
    let message: ChatMessage

    var body: some View {
        Group {
            if message.role == .user {
                userLine
            } else {
                assistantLine
            }
        }
    }

    private var userLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.text)
                .textSelection(.enabled)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            if message.hasImage {
                Label("Screen attached", systemImage: "camera.viewfinder")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.leading, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantLine: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.blue.opacity(0.85)))

            VStack(alignment: .leading, spacing: 4) {
                if message.isSearching {
                    Label("Searching the web…", systemImage: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text(displayText)
                    .textSelection(.enabled)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var displayText: String {
        if message.isStreaming, message.text.isEmpty, !message.isSearching {
            return "▍"
        }
        return PointTag.strippingTrailingTag(message.text)
    }
}

// MARK: - Keycap badge

private struct KeycapLabel: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}
