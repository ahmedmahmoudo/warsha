import SwiftUI

/// The profile switcher in the toolbar, once there's more than one profile.
struct ProfileMenu: View {
  @Environment(AppState.self) private var state
  @State private var naming = false

  var body: some View {
    Menu {
      ProfileMenuItems(naming: $naming)
    } label: {
      Label(state.profile.name, systemImage: "person.crop.circle")
        .labelStyle(.titleAndIcon)
    }
    .help("Switch profile")
    .clickable()
    .sheet(isPresented: $naming) { NewProfileSheet() }
  }
}

/// Each profile to switch to, the current one ticked, then New Profile…; shared by the toolbar and
/// the menu bar.
struct ProfileMenuItems: View {
  @Binding var naming: Bool
  @Environment(AppState.self) private var state

  var body: some View {
    ForEach(state.profiles) { profile in
      Toggle(profile.name, isOn: Binding(get: { state.profile.id == profile.id }, set: { if $0 { state.switchProfile(to: profile.id) } }))
    }
    Divider()
    Button("New Profile…") { naming = true }
    SettingsLink { Text("Manage Profiles…") }
  }
}

/// Names a new profile; making it switches to it, and Get started asks for its accounts.
struct NewProfileSheet: View {
  @Environment(AppState.self) private var state
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Profile").scaledFont(.headline)
      Text("A profile is a separate Workbench: its own GitHub, Linear and Google accounts, settings, pins and notes. Switch between them from the toolbar or the menu bar.")
        .scaledFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      TextField("Name", text: $name, prompt: Text("Work, Client, Personal…"))
        .onSubmit(create)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).clickable()
        Button("Create and Switch", action: create).keyboardShortcut(.defaultAction).clickable()
      }
    }
    .padding(20)
    .scaledFrame(width: 380)
  }

  private func create() {
    dismiss()
    state.createProfile(named: name)
  }
}

/// Settings → Accounts: the profiles, with the one in use; rename, add and delete them.
struct ProfilesSection: View {
  @Environment(AppState.self) private var state
  @State private var naming = false
  @State private var deleting: Profile?

  var body: some View {
    Section {
      ForEach(state.profiles) { profile in
        HStack {
          ProfileName(profile: profile)
          if profile.id == state.profile.id {
            Text("In use").scaledFont(.caption).foregroundStyle(.secondary)
          } else {
            Button("Switch") { state.switchProfile(to: profile.id) }.clickable()
          }
          if profile.id != Profiles.defaultID {
            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = profile }
              .labelStyle(.iconOnly).buttonStyle(.borderless).clickable().help("Delete this profile")
          }
        }
      }
      Button("New Profile…", systemImage: "plus") { naming = true }.clickable()
    } header: {
      Text("Profiles")
    } footer: {
      Text("Everything on this page belongs to the profile in use. Each profile has its own accounts, settings, pins, notes, todos and open tabs.")
        .foregroundStyle(.secondary)
    }
    .sheet(isPresented: $naming) { NewProfileSheet() }
    .confirmationDialog(
      "Delete the profile \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { profile in
      Button("Delete Profile", role: .destructive) { state.deleteProfile(profile.id) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Its sign-ins, settings, pins, notes, todos and parked items are deleted from this Mac. Your accounts themselves aren't touched.")
    }
  }
}

/// A profile's name, edited in place.
private struct ProfileName: View {
  let profile: Profile
  @Environment(AppState.self) private var state
  @State private var name = ""

  var body: some View {
    TextField("Name", text: $name)
      .labelsHidden()
      .textFieldStyle(.plain)
      .onAppear { name = profile.name }
      .onSubmit { state.renameProfile(profile.id, to: name) }
      .onChange(of: name) { _, value in if !value.trimmingCharacters(in: .whitespaces).isEmpty { state.renameProfile(profile.id, to: value) } }
  }
}
