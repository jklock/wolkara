import SwiftUI

/// The games Tolkara has on the device, with what can be done to each:
/// update after the game changed on this Mac, copy again, remove.
struct LibraryView: View {
    @Environment(SetupModel.self) private var model
    @State private var removing: DeviceFolder?

    var body: some View {
        StepPage(step: .library, summary: "The games Tolkara has on \(model.deviceName). Update one after Battle.net or another store updated it on this Mac, or remove one to free space.") {
            content
        }
        .task(id: model.state.device) {
            if model.library?.deviceID != model.state.device || model.library == nil { await model.readLibrary() }
        }
        .confirmationDialog(removing.map { "Remove \($0.name) from \(model.deviceName)?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { folder in
            Button("Remove \(folder.size.bytes)", role: .destructive) { model.remove(folder) }
        } message: { folder in
            Text("This deletes \(folder.games.map(\.name).formatted()) and everything in the “\(folder.name)” folder from the \(model.deviceWord), including its settings and saved files there. Your copy on this Mac stays, and you can copy it again later.")
        }
    }

    @ViewBuilder private var content: some View {
        AdoptCallout()
        if model.readingLibrary && model.library == nil {
            CheckRow("Reading Tolkara's files on \(model.deviceName)…", status: .checking)
        } else if let error = model.libraryError, model.library == nil {
            Callout(.warning, "The library could not be read", message: error) {
                HStack {
                    Button("Try Again") { Task { await model.readLibrary() } }
                    if !model.isComplete(.iPad) { Button("Go to \(SetupStep.iPad.title)") { model.selection = .iPad } }
                }
            }
        } else if let library = model.library {
            if library.folders.isEmpty {
                Callout(.info, "No games on \(model.deviceName) yet", message: "Choose a game and copy it over to see it here.") {
                    Button("Choose a Game") { model.selection = .game }
                }
            }
            ForEach(library.folders) { folder in
                FolderSection(folder: folder) { removing = folder }
            }
            if library.folders.contains(where: { $0.games.contains { $0.profile?.firstRun != nil } }) {
                Text("Changed your region or language in Battle.net? Start the game once on this Mac and quit it, then choose **Copy Again** in the game's \(Image(systemName: "ellipsis.circle")) menu. Only the region and language are copied; the game's other settings on the \(model.deviceWord) stay.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            notOnDevice(library)
            HStack {
                if model.readingLibrary { ProgressView().controlSize(.small) }
                Text("Read \(library.loaded.formatted(date: .omitted, time: .shortened)).").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open Tolkara on \(model.deviceWord)") { model.openOnDevice() }
                    .disabled(model.job?.isRunning == true || model.selectedDevice?.available != true)
            }
            if let job = model.lastJobs[.launch], job.failure != nil { JobPanel(job: job) }
        }
    }

    /// Games this app can set up that the device does not have yet.
    @ViewBuilder private func notOnDevice(_ library: DeviceLibrary) -> some View {
        let present = Set(library.folders.flatMap(\.games).map(\.id))
        let missing = model.setupProfiles.filter { !present.contains($0.id) }
        if !missing.isEmpty {
            Form {
                Section("Not on your \(model.deviceWord) yet") {
                    ForEach(missing) { profile in
                        CheckRow(profile.name, detail: model.executableFound(for: profile) ? "Found on this Mac." : "Not found on this Mac.",
                                 status: .waiting) {
                            Button("Set Up…") {
                                if !model.state.profiles.contains(profile.id) {
                                    if profile.risk == nil || model.riskAccepted(profile) { model.toggle(profile) }
                                }
                                model.selection = .game
                            }
                        }
                    }
                }
            }
            .pageForm()
        }
    }
}

private struct FolderSection: View {
    @Environment(SetupModel.self) private var model
    var folder: DeviceFolder
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                Section {
                    ForEach(folder.games) { game in GameRow(game: game) }
                } header: {
                    HStack {
                        Label(folder.name, systemImage: "folder")
                        Spacer()
                        Text(folder.size.bytes).foregroundStyle(.secondary).monospacedDigit()
                        Menu {
                            Button("Remove from \(model.deviceWord)…", role: .destructive, action: remove)
                                .disabled(model.job?.isRunning == true || !model.canRemoveFromDevice || model.selectedDevice?.available != true)
                            if !model.canRemoveFromDevice {
                                Text("Install Tolkara with this app first to remove games from here.")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More for \(folder.name)")
                    }
                } footer: {
                    if folder.games.count > 1 {
                        Text("These games share this folder on the \(model.deviceWord).").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .pageForm()
            if let job = model.lastJobs[.remove(folder.name)] { JobPanel(job: job) }
        }
    }
}

private struct GameRow: View {
    @Environment(SetupModel.self) private var model
    var game: DeviceGame

    private var macCopy: MacCopy? {
        guard let profile = game.profile, model.executableFound(for: profile), let folder = model.sourceFolder(for: profile) else { return nil }
        return MacCopy.of(profile.executable(inSource: folder))
    }

    private var settings: DeviceSettings {
        guard let profile = game.profile else { return .fine }
        return DeviceSettings.compare(mac: model.firstRun(for: profile), device: game.firstRun)
    }

    var body: some View {
        let mac = macCopy
        let outdated = mac?.isNewer(than: game) == true
        let settings = settings
        let busy = model.job?.isRunning == true || model.selectedDevice?.available != true
        VStack(alignment: .leading, spacing: 8) {
            CheckRow(game.name, detail: detail(mac: mac, outdated: outdated, settings: settings),
                     status: outdated || !settings.isFine ? .warning : .ok) {
                if let profile = game.profile, profile.hasSetup || profile.isImported {
                    if outdated {
                        // Update copies the region and language too.
                        Button("Update") { model.updateGame(profile) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                    } else if case .copyAgain = settings {
                        Button("Copy Again") { model.copy(profile) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                    } else if case .startOnMac = settings, let getApp = profile.getApp {
                        Button("Open \(getApp.name)") { model.openGetApp(profile) }
                            .buttonStyle(.borderedProminent)
                    }
                    Menu {
                        Button("Copy Again") { model.copy(profile) }
                        if let folder = model.sourceFolder(for: profile) {
                            Button("Show on This Mac") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(model.job?.isRunning == true)
                    .accessibilityLabel("More for \(game.name)")
                }
            }
            if let profile = game.profile, let job = model.lastJobs[.copy(profile.id)], job.isRunning || job.failure != nil {
                JobPanel(job: job)
            }
        }
    }

    private func detail(mac: MacCopy?, outdated: Bool, settings: DeviceSettings) -> String {
        var parts: [String] = []
        switch settings {
        case .fine: break
        case .startOnMac:
            return "Its region and language are missing on the \(model.deviceWord), so it quits right after it starts. Start the game once from Battle.net on this Mac (choose your region, log in, quit), then choose Copy Again."
        case .copyAgain(let changed):
            parts.append(changed ? "Region or language changed on this Mac: Copy Again brings them over"
                                 : "Its region and language are missing on the \(model.deviceWord): Copy Again brings them over")
        }
        if let version = game.version { parts.append("Version \(version)") }
        if let played = game.lastLaunched { parts.append("played \(played.formatted(.relative(presentation: .named)))") }
        if outdated, let mac {
            parts.append(mac.version.map { "this Mac has \($0)" } ?? "updated on this Mac")
        } else if mac != nil {
            parts.append("same as on this Mac")
        } else if game.profile == nil {
            parts.append("added on the \(model.deviceWord)")
        }
        return parts.joined(separator: " · ")
    }
}
