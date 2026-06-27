import SwiftUI

/// The Chingu chat overlay UI. A fixed-size, scrollable single thread with a
/// send-on-Enter composer. Hosted (via NSHostingView) inside the non-activating
/// panel; also runnable standalone in a window for development.
struct ChatView: View {
    @ObservedObject var model: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            thread
            Divider()
            composer
        }
        .frame(width: 520, height: 520)            // fixed size; history scrolls
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    // Anchor we can always scroll to as tokens stream in.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(12)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Chingu")
                .font(.headline)
            if missing.isEmpty {
                Text("Ask anything. I can search the web when I need current info.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Surface missing required keys up front, before the user even types,
                // so setup is obvious on first launch. (Never shows key values.)
                Label("Setup needed", systemImage: "key.slash")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(Secrets.setupMessage(for: missing))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            // .plain + manual styling so the placeholder reads as guidance and the
            // field clears on input automatically (it's bound to model.input, which
            // send() empties). onSubmit gives us send-on-Enter.
            TextField("Write your question/prompt here", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit(model.send)                // Enter sends
                .submitLabel(.send)

            Button(action: model.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary)
            .disabled(!model.canSend)
            .keyboardShortcut(.return, modifiers: [])   // Enter also fires the button
        }
        .padding(10)
    }

    private static let bottomAnchor = "chingu.bottom.anchor"
}

/// One message bubble. User messages right-aligned and tinted; assistant messages
/// left-aligned. Shows a "Searching the web…" hint and a caret while streaming.
private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.isSearching {
                    Label("Searching the web…", systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(displayText)
                    .textSelection(.enabled)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    /// While an assistant reply is mid-stream and has no text yet, show a thinking
    /// caret so the bubble isn't blank.
    private var displayText: String {
        if message.role == .assistant, message.isStreaming, message.text.isEmpty,
           !message.isSearching {
            return "▍"
        }
        return message.text
    }

    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor : Color.white.opacity(0.08)
    }
}
