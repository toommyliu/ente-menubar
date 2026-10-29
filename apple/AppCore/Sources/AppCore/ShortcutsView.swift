import SwiftUI

struct ShortcutsView: View {
  @Bindable var model: AppModel
  let editor: ShortcutEditor

  var body: some View {
    let layout = KeyLayout.current
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Keyboard Shortcuts").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
        Spacer()
        Button("Done") { model.closeShortcuts() }.keyboardShortcut(.defaultAction)
      }
      section("From any app", global: true, layout)
      section("While Ente Auth is open", global: false, layout)
      Text("Always available: ↑ ↓ choose a code, ↩ copies it, ⎋ clears or closes, hold ⌥ to show hidden codes, ⌘Q quits.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button("Restore Defaults") { model.restoreDefaultShortcuts() }
        .disabled(model.keymap.isDefault)
    }
    .padding(18)
  }

  private func section(_ title: String, global: Bool, _ layout: KeyLayout) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      ForEach(ShortcutAction.allCases.filter { $0.isGlobal == global }, id: \.self) { action in
        ShortcutRow(
          title: action.title, combo: model.keymap.combo(for: action), recording: isRecording(action),
          problem: problem(for: action), layout: layout,
          toggleRecording: { model.setRecording(isRecording(action) ? nil : action) },
          clear: { model.clearShortcut(action) })
      }
    }
  }

  private func isRecording(_ action: ShortcutAction) -> Bool {
    if case .recording(let current, _) = editor { return current == action }
    return false
  }

  private func problem(for action: ShortcutAction) -> ShortcutProblem? {
    if case .recording(let current, let problem) = editor, current == action { return problem }
    if action.isGlobal, let combo = model.unavailableGlobalShortcut { return .unavailable(combo) }
    return nil
  }
}

private struct ShortcutRow: View {
  let title: String
  let combo: KeyCombo?
  let recording: Bool
  let problem: ShortcutProblem?
  let layout: KeyLayout
  let toggleRecording: () -> Void
  let clear: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button(action: toggleRecording) {
          Text(recording ? "Type Shortcut" : combo?.label(in: layout) ?? "None")
            .frame(minWidth: 104)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .accessibilityLabel("\(title) shortcut")
        .accessibilityValue(recording ? "Recording" : combo?.label(in: layout) ?? "None")
        .accessibilityHint(recording ? "Press the new shortcut, or Escape to cancel" : "Records a new shortcut")
        Button(action: clear) { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .frame(width: 24, height: 24).contentShape(Rectangle())
          .opacity(combo == nil || recording ? 0 : 1).disabled(combo == nil || recording)
          .accessibilityLabel("Clear \(title) shortcut")
      }
      if let problem {
        Text(problem.message(in: layout)).font(.system(size: 11))
          .foregroundStyle(recording ? Color.red : Color.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
