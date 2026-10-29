import AppKit
import SwiftUI

struct PasswordField: NSViewRepresentable {
  @Binding var text: String
  var onSubmit: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSSecureTextField {
    let field = NSSecureTextField()
    field.placeholderString = "Password"
    field.setAccessibilityLabel("Password")
    field.controlSize = .large
    field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
    field.bezelStyle = .roundedBezel
    // AppKit infers AutoFill for nil content types. Both settings suppress its suggestions.
    // https://developer.apple.com/forums/thread/821395
    field.contentType = .newPassword
    field.isAutomaticTextCompletionEnabled = false
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.submit)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: NSSecureTextField, context: Context) {
    context.coordinator.parent = self
    field.isEnabled = isEnabled
    if field.stringValue != text { field.stringValue = text }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSecureTextField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
  }

  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: PasswordField

    init(_ parent: PasswordField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSecureTextField else { return }
      parent.text = field.stringValue
    }

    @objc func submit() { parent.onSubmit() }
  }
}
