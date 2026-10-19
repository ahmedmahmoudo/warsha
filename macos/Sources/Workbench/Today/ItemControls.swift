import SwiftUI

// Pin, note and park controls for any ticket or PR: src/components/StoreButtons.tsx in SwiftUI.

/// The comment a park reason becomes on Linear and GitHub; the popover previews exactly this.
func parkComment(_ reason: String, until: String?) -> String {
  var text = "Parked: \(reason.trimmingCharacters(in: .whitespacesAndNewlines))"
  if let until {
    text += "\n\nPicking this back up on \(Formats.day(until, "EEEdMMM"))."
  }
  return text
}

/// Where a park reason can be posted, and how each post went.
struct PostTarget: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case linear(key: String)
    case github(repo: String, number: Int)
  }
  let kind: Kind

  var label: String {
    switch kind {
    case let .linear(key): "Linear \(key)"
    case let .github(_, number): "PR #\(number)"
    }
  }

  /// Where a park reason can go for this item: its Linear ticket and its PRs.
  static func targets(for ref: Ref, prs: [PrKey]) -> [PostTarget] {
    var targets: [PostTarget] = []
    if ref.hasPrefix("ticket:") { targets.append(PostTarget(kind: .linear(key: String(ref.dropFirst(7))))) }
    var all = prs
    if let match = ref.wholeMatch(of: /pr:(.+)#(\d+)/), let number = Int(match.2) {
      all.insert(PrKey(repo: String(match.1), number: number), at: 0)
    }
    for pr in all where !targets.contains(PostTarget(kind: .github(repo: pr.repo, number: pr.number))) {
      targets.append(PostTarget(kind: .github(repo: pr.repo, number: pr.number)))
    }
    return targets
  }
}

struct PostResult: Identifiable, Sendable {
  var id: String { label }
  let label: String
  let url: String?
  let error: String?
}

extension Store {
  /// Parks an item and posts the reason to each target. The park is saved even if a post fails;
  /// each result says how it went.
  func park(_ ref: Ref, title: String, url: String?, reason: String?, until: String?, postTo: [PostTarget], config: PrConfig) async -> [PostResult] {
    park(ref, title: title, url: url, reason: reason, until: until)
    guard let reason, !postTo.isEmpty else { return [] }
    let comment = parkComment(reason, until: until)
    return await withTaskGroup(of: (Int, PostResult).self) { group in
      for (index, target) in postTo.enumerated() {
        group.addTask {
          do {
            let link = switch target.kind {
            case let .linear(key): try await Linear.comment(on: key, body: comment, apiKey: config.linearApiKey)
            case let .github(repo, number): try await GitHub.comment(on: repo, number: number, body: comment, token: config.githubToken)
            }
            return (index, PostResult(label: target.label, url: link, error: nil))
          } catch {
            return (index, PostResult(label: target.label, url: nil, error: error.localizedDescription))
          }
        }
      }
      var results: [(Int, PostResult)] = []
      for await result in group { results.append(result) }
      return results.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  /// What's parked right now: an item whose "until" date has passed is back in play.
  func activeParked(_ ref: Ref) -> Parked? {
    guard let item = parkedByRef[ref], item.until.map({ $0 >= Store.today }) ?? true else { return nil }
    return item
  }

  var activeParkedItems: [Parked] {
    let today = Store.today
    return parked.filter { $0.until == nil || $0.until! >= today }
  }
}

/// Puts text on the clipboard, replacing what was there.
func copyToPasteboard(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}

/// Copy link, pin, note and park for one item. The link is the PR's (a menu when there are several).
struct ItemControls: View {
  let ref: Ref
  let title: String
  let url: String?
  var prs: [PrKey] = []
  /// Off where the row already has its own Copy link button.
  var copyLink = true

  var body: some View {
    HStack(spacing: 2) {
      if copyLink && !prs.isEmpty { CopyLinkIcon(prs: prs) }
      PinButton(ref: ref, title: title, url: url)
      NoteButton(ref: ref, label: title)
      ParkButton(ref: ref, title: title, url: url, prs: prs)
    }
  }
}

/// Copies a PR's link, with a tick for a moment so you know it worked.
struct CopyLinkIcon: View {
  let prs: [PrKey]
  @State private var copied = false

  var body: some View {
    if prs.count == 1, let pr = prs.first {
      Button { copy(pr) } label: { ControlIcon(symbol: copied ? "checkmark" : "link", active: copied, activeColor: Tone.good.color) }
        .buttonStyle(.plain)
        .clickable()
        .help("Copy link to #\(pr.number)")
    } else {
      Menu {
        ForEach(prs, id: \.self) { pr in Button("Copy \(pr.repo)#\(pr.number)") { copy(pr) } }
        Button("Copy All") { copy(prs.map(\.url).joined(separator: "\n")) }
      } label: {
        ControlIcon(symbol: copied ? "checkmark" : "link", active: copied, activeColor: Tone.good.color)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .clickable()
      .help("Copy a PR's link")
    }
  }

  private func copy(_ pr: PrKey) { copy(pr.url) }

  private func copy(_ text: String) {
    copyToPasteboard(text)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }
}

/// Copies the PR's link as a labelled pill, for rows where copying it is the next step (sending
/// it for review, nudging). Copying isn't sending, so Sent and Nudged stay their own buttons.
struct CopyLinkButton: View {
  let url: String
  @State private var copied = false

  var body: some View {
    Button(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link") {
      copyToPasteboard(url)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(2))
        copied = false
      }
    }
    .buttonStyle(.pill(.info))
    .clickable()
    .help("Copy the PR link")
  }
}

private struct ControlIcon: View {
  let symbol: String
  let active: Bool
  var activeColor: Color = Tone.info.color

  var body: some View {
    Image(systemName: symbol)
      .scaledFont(.caption)
      .foregroundStyle(active ? AnyShapeStyle(activeColor) : AnyShapeStyle(.tertiary))
      .scaledFrame(width: 22, height: 22)
      .contentShape(.rect)
  }
}

struct PinButton: View {
  let ref: Ref
  let title: String
  let url: String?
  @Environment(Store.self) private var store

  var body: some View {
    let pinned = store.pins.contains { $0.ref == ref }
    Button {
      if pinned { store.unpin(ref) } else { store.pin(ref, title: title, url: url) }
    } label: {
      ControlIcon(symbol: pinned ? "pin.fill" : "pin", active: pinned)
    }
    .buttonStyle(.plain)
    .clickable()
    .help(pinned ? "Unpin from focus" : "Pin to focus")
  }
}

struct NoteButton: View {
  let ref: Ref
  let label: String
  @Environment(Store.self) private var store
  @State private var open = false
  @State private var draft = ""

  var body: some View {
    let note = store.notes.first { $0.ref == ref }
    Button {
      draft = note?.body ?? ""
      open = true
    } label: {
      ControlIcon(symbol: note == nil ? "note.text" : "note.text.badge.plus", active: note != nil, activeColor: Tone.warn.color)
    }
    .buttonStyle(.plain)
    .clickable()
    .help(note?.body ?? "Add a note")
    .popover(isPresented: $open, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Note on \(Text(label).fontWeight(.medium))\(note.map { " · edited \(relative($0.updatedAt))" } ?? "")")
          .scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
        TextEditor(text: $draft)
          .scaledFont(.callout)
          .scaledFrame(height: 90)
          .frame(maxWidth: .infinity)
          .scrollContentBackground(.hidden)
          .padding(4)
          .background(Palette.fill, in: .rect(cornerRadius: 6))
        HStack {
          Text("⌘↵ to save").scaledFont(.caption2).foregroundStyle(.tertiary)
          Spacer()
          if note != nil {
            Button("Delete", role: .destructive) {
              store.setNote(ref, body: "")
              open = false
            }
            .clickable()
          }
          Button("Save") {
            store.setNote(ref, body: draft)
            open = false
          }
          .keyboardShortcut(.return, modifiers: .command)
          .clickable()
          .buttonStyle(.borderedProminent)
        }
        .scaledControlSize(.small)
      }
      // A fixed width for the whole popover, so a long title wraps instead of leaving the editor
      // narrower than the popover.
      .scaledFrame(width: 320, alignment: .leading)
      .padding(12)
    }
  }
}

struct ParkButton: View {
  let ref: Ref
  let title: String
  let url: String?
  let prs: [PrKey]
  @Environment(Store.self) private var store
  @Environment(AppSettings.self) private var settings
  @State private var open = false
  @State private var reason = ""
  @State private var until: Date?
  @State private var chosen = Set<PostTarget>()
  @State private var results: [PostResult]?
  @State private var saving = false

  var body: some View {
    let parked = store.activeParked(ref)
    Button {
      reason = parked?.reason ?? ""
      until = parked?.until.flatMap { TodayRules.parseInstant("\($0)T12:00:00Z") }
      // Posting is on by default when first parking; re-saving an existing park doesn't repost.
      chosen = parked == nil ? Set(PostTarget.targets(for: ref, prs: prs)) : []
      results = nil
      open = true
    } label: {
      ControlIcon(symbol: parked == nil ? "parkingsign.circle" : "parkingsign.circle.fill", active: parked != nil)
    }
    .buttonStyle(.plain)
    .clickable()
    .help(parked.map { "Parked\($0.reason.map { ": \($0)" } ?? "")" } ?? "Park: stop it asking for attention")
    .popover(isPresented: $open, arrowEdge: .bottom) { popover(parked) }
  }

  private var untilText: String? {
    until.map { TodayRules.localDate($0, TimeZone.current.identifier) }
  }

  private func popover(_ parked: Parked?) -> some View {
    let targets = PostTarget.targets(for: ref, prs: prs)
    let hasReason = !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let postTo = hasReason ? targets.filter(chosen.contains) : []
    return VStack(alignment: .leading, spacing: 10) {
      Text("\(parked == nil ? "Park" : "Parked") \(Text(title).fontWeight(.medium))\(parked.map { " · \(relative($0.parkedAt))" } ?? "")")
        .scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
      if let results {
        Text("Parked.").scaledFont(.caption).foregroundStyle(Tone.good.color)
        ForEach(results) { result in
          if let error = result.error {
            Text("Couldn't post to \(result.label): \(error)").scaledFont(.caption).foregroundStyle(Tone.bad.color)
          } else if let link = result.url.flatMap(URL.init(string:)) {
            HStack(spacing: 4) {
              Text("Posted to").foregroundStyle(.secondary)
              Link(result.label, destination: link).clickable(underline: true)
            }
            .scaledFont(.caption)
          }
        }
        HStack { Spacer(); Button("Done") { open = false }.buttonStyle(.borderedProminent).scaledControlSize(.regular).clickable() }
      } else {
        Text("Parked items leave Today, the attention counts and the stuck flags until you unpark them.")
          .scaledFont(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        TextField("Why? (optional)", text: $reason).textFieldStyle(.roundedBorder)
        HStack {
          Toggle("Bring back on", isOn: Binding(get: { until != nil }, set: { until = $0 ? (until ?? Date().addingTimeInterval(7 * 86_400)) : nil }))
          Spacer()
          if until != nil {
            DatePicker("Date", selection: Binding(get: { until ?? Date() }, set: { until = $0 }), displayedComponents: .date)
              .labelsHidden()
          }
        }
        .scaledFont(.caption)
        if !targets.isEmpty {
          GroupBox("Post the reason as a comment on") {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 12) {
                ForEach(targets, id: \.self) { target in
                  Toggle(target.label, isOn: Binding(
                    get: { chosen.contains(target) },
                    set: { if $0 { chosen.insert(target) } else { chosen.remove(target) } }
                  ))
                  .toggleStyle(.checkbox)
                  .disabled(!hasReason)
                }
              }
              if hasReason {
                if !postTo.isEmpty {
                  Text(parkComment(reason, until: untilText))
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.fill, in: .rect(cornerRadius: 4))
                }
              } else {
                Text("Add a reason to post it.").scaledFont(.caption).foregroundStyle(.tertiary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .scaledFont(.caption)
          .opacity(hasReason ? 1 : 0.6)
        }
        HStack {
          Spacer()
          if parked != nil {
            Button("Unpark") {
              store.unpark(ref)
              open = false
            }
            .clickable()
          }
          Button(saving ? (postTo.isEmpty ? "Saving…" : "Posting…") : postTo.isEmpty ? (parked == nil ? "Park" : "Update") : "\(parked == nil ? "Park" : "Update") & Post") {
            Task { await save(postTo: postTo) }
          }
          .buttonStyle(.borderedProminent)
          .clickable()
          .disabled(saving)
        }
        .scaledControlSize(.small)
      }
    }
    .padding(12)
    .scaledFrame(width: 340)
  }

  private func save(postTo: [PostTarget]) async {
    saving = true
    defer { saving = false }
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let posted = await store.park(
      ref, title: title, url: url, reason: trimmed.isEmpty ? nil : trimmed, until: untilText, postTo: postTo, config: PrConfig(settings)
    )
    if posted.isEmpty { open = false } else { results = posted }
  }
}

/// The note on an item, under it, when there is one.
struct NoteLine: View {
  let ref: Ref
  @Environment(Store.self) private var store

  var body: some View {
    if let note = store.notes.first(where: { $0.ref == ref }) {
      Label(note.body, systemImage: "note.text")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }
}
