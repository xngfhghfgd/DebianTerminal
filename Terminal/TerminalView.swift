//
//  TerminalView.swift
//  DebianTerminal
//
//  SwiftUI terminal surface. Renders the guest's serial transcript and
//  forwards typed keys to TerminalSession / VMManager.
//

import SwiftUI
import UIKit

struct TerminalView: View {
    @ObservedObject var session: TerminalSession
    let onKey: (TerminalKey) -> Void

    @State private var inputField = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.transcript)
                        .font(.system(size: session.fontSize, design: .monospaced))
                        .foregroundColor(Color(.sRGB, red: 0.85, green: 0.92, blue: 0.86, opacity: 1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .id("top")
                }
                .background(Color.black)
                .onChange(of: session.flushVersion) { _ in
                    proxy.scrollTo("top", anchor: .bottom)
                }
            }

            // A minimal in-line input line reconstructed for the prompt.
            HStack(spacing: 4) {
                Text("$")
                    .font(.system(size: session.fontSize, design: .monospaced))
                    .foregroundColor(.green)
                TextField("", text: $inputField)
                    .font(.system(size: session.fontSize, design: .monospaced))
                    .foregroundColor(.white)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .focused($focused)
                    .onSubmit(sendLine)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .background(Color(white: 0.08))
        }
        .onTapGesture { focused = true }
        // Simple hardware/soft key handling is wired via the overlay below.
        .modifier(TerminalKeyModifier(onKey: onKey))
    }

    private func sendLine() {
        session.writeLine(inputField)
        inputField = ""
        focused = true
    }
}

/// Captures hardware keyboard keys (arrows, Ctrl, Tab, Esc, etc.) and forwards
/// them as TerminalKey events.
struct TerminalKeyModifier: ViewModifier {
    let onKey: (TerminalKey) -> Void

    func body(content: Content) -> some View {
        content
            .background(KeyboardCapturer(onKey: onKey))
    }
}

/// A hidden UIView that overrides key presses for hardware keyboards.
final class KeyboardCapturer: UIViewControllerRepresentable {
    let onKey: (TerminalKey) -> Void
    init(onKey: @escaping (TerminalKey) -> Void) { self.onKey = onKey }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = KeyCaptureViewController()
        vc.onKey = onKey
        return vc
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class KeyCaptureViewController: UIViewController {
        var onKey: ((TerminalKey) -> Void)?
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for press in presses {
                guard let key = press.key else { continue }
                let kc = key.keyCode
                let chars = key.charactersIgnoringModifiers
                let modifiers = key.modifierFlags
                if modifiers.contains(.control) {
                    onKey?(.ctrl("c"))
                    continue
                }
                switch kc {
                case .keyboardReturnOrEnter: onKey?(.enter)
                case .keyboardTab: onKey?(.tab)
                case .keyboardEscape: onKey?(.esc)
                case .keyboardDeleteForward: onKey?(.delete)
                case .keyboardDeleteOrBackspace: onKey?(.backspace)
                case .keyboardUpArrow: onKey?(.up)
                case .keyboardDownArrow: onKey?(.down)
                case .keyboardLeftArrow: onKey?(.left)
                case .keyboardRightArrow: onKey?(.right)
                case .keyboardHome: onKey?(.home)
                case .keyboardEnd: onKey?(.end)
                case .keyboardPageUp: onKey?(.pageUp)
                case .keyboardPageDown: onKey?(.pageDown)
                default:
                    if let c = chars.first, c.isLetter {
                        onKey?(.ctrl(Character(c.lowercased())))
                    }
                }
            }
        }
    }
}
