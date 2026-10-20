// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct OfflineDownload: Codable, Identifiable {
    let programme: Programme
    let folderName: String
    let saved: Date
    let quality: String
    let videoRange: String?
    let bytes: Int64
    var id: String { programme.id }
}
struct DownloadProgress {
    let programme: Programme
    var fraction: Double = 0
    var status = "Finding the best available quality…"
}
@MainActor final class DownloadStore: ObservableObject {
    @Published private(set) var downloads: [OfflineDownload] = []
    @Published private(set) var active: [String: DownloadProgress] = [:]
    @Published var errors: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BeebDownloads-v1")
        reconcile()
    }
    func reconcile() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        downloads = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("download.json")),
                  let entry = try? JSONDecoder().decode(OfflineDownload.self, from: data),
                  entry.folderName == folder.lastPathComponent,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("master.m3u8").path) else { return nil }
            // Detect partial cache eviction before offering playback.
            guard let inventory = try? Data(contentsOf: folder.appendingPathComponent("inventory.json")),
                  let files = try? JSONDecoder().decode([String].self, from: inventory),
                  files.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) else { return nil }
            return entry
        }.sorted { $0.saved > $1.saved }
    }
    func folder(for entry: OfflineDownload) -> URL { root.appendingPathComponent(entry.folderName) }
    func contains(_ programme: Programme) -> Bool { downloads.contains { $0.id == programme.id } }
    func cancel(_ id: String) { tasks[id]?.cancel() }
    func remove(_ entry: OfflineDownload) {
        do { try FileManager.default.removeItem(at: folder(for: entry)); downloads.removeAll { $0.id == entry.id } }
        catch { errors[entry.id] = error.localizedDescription }
    }
    func start(_ programme: Programme) {
        guard active[programme.id] == nil, !contains(programme) else { return }
        errors[programme.id] = nil; active[programme.id] = DownloadProgress(programme: programme)
        tasks[programme.id] = Task {
            let staging = root.appendingPathComponent("partial-" + UUID().uuidString)
            defer { active[programme.id] = nil; tasks[programme.id] = nil; try? FileManager.default.removeItem(at: staging) }
            do {
                let package: OfflinePackage
                do {
                    if UHDIdentityVault.isConfigured {
                        let manifest = try await UHDPlaybackAccess().manifest(for: programme).manifest
                        package = OfflinePackage.dash(manifest)
                    } else {
                        let source = try await UHDService().source(for: programme)
                        var result = try await OfflinePackage.build(url: source.url, fetch: BBCService().fetch)
                        if result.height == 0 { result = OfflinePackage(playlists: result.playlists, media: result.media, height: 2160, videoRange: source.videoRange) }
                        package = result
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    let source = try await BBCService().source(for: programme, require1080: false)
                    var result = try await OfflinePackage.build(url: source.url, fetch: BBCService().fetch)
                    if result.height == 0 && source.requested1080 { result = OfflinePackage(playlists: result.playlists, media: result.media, height: 1080, videoRange: nil) }
                    package = result
                }
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let quality = PlaybackPolicy.badge(height: package.height, videoRange: package.videoRange) ?? "Best available"
                active[programme.id]?.status = "Downloading • " + quality
                let entries = Array(package.media).sorted { $0.key < $1.key }
                var bytes: Int64 = 0, completed = 0
                // Four segments at a time keeps memory bounded and makes large 4K episodes practical.
                try await withThrowingTaskGroup(of: Int64.self) { group in
                    var index = 0
                    func enqueue(_ entry: (key: String, value: URL)) {
                        group.addTask {
                            try Task.checkCancellation()
                            let data = try await BBCService().fetch(entry.value)
                            let body = entry.key.hasSuffix(".m4s") && package.videoRange == "HLG" ? try FMP4Normalizer.normalize(data) : data
                            try Task.checkCancellation()
                            try body.write(to: staging.appendingPathComponent(entry.key), options: .atomic)
                            return Int64(body.count)
                        }
                    }
                    while index < min(4, entries.count) { enqueue(entries[index]); index += 1 }
                    while let size = try await group.next() {
                        bytes += size; completed += 1
                        active[programme.id]?.fraction = Double(completed) / Double(max(1, entries.count))
                        if index < entries.count { enqueue(entries[index]); index += 1 }
                    }
                }
                try Task.checkCancellation()
                for (name, data) in package.playlists { try data.write(to: staging.appendingPathComponent(name), options: .atomic) }
                let inventory = Array(package.playlists.keys) + Array(package.media.keys)
                try JSONEncoder().encode(inventory).write(to: staging.appendingPathComponent("inventory.json"), options: .atomic)
                let name = UUID().uuidString
                let entry = OfflineDownload(programme: programme, folderName: name, saved: Date(), quality: quality, videoRange: package.videoRange, bytes: bytes)
                try JSONEncoder().encode(entry).write(to: staging.appendingPathComponent("download.json"), options: .atomic)
                try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(name))
                downloads.insert(entry, at: 0)
            } catch { if !Task.isCancelled { errors[programme.id] = error.localizedDescription } }
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var store: DownloadStore
    @StateObject private var playback = PlaybackModel()
    @State private var playing = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Downloads").font(.largeTitle).bold()
                Text("Best available quality, with 4K preferred. Keep Beeb open while downloading. Apple TV may clear downloads when it needs space.").font(.callout).foregroundStyle(.secondary)
                if store.downloads.isEmpty && store.active.isEmpty { Text("Open an episode and choose Download to watch it later.").foregroundStyle(.secondary) }
                ForEach(store.active.keys.sorted(), id: \.self) { id in
                    if let item = store.active[id] {
                        HStack(spacing: 28) {
                            VStack(alignment: .leading) {
                                Text(item.programme.title).font(.headline)
                                Text(item.status).font(.callout).foregroundStyle(.secondary)
                                ProgressView(value: item.fraction)
                                Text("\(Int(item.fraction * 100))%").font(.caption)
                            }
                            Button("Cancel") { store.cancel(id) }
                        }.padding(24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                ForEach(store.errors.keys.sorted(), id: \.self) { id in
                    Text(store.errors[id] ?? "").foregroundStyle(.orange).font(.callout)
                }
                if let error = playback.error { Text(error).foregroundStyle(.orange) }
                ForEach(store.downloads) { entry in
                    HStack(spacing: 28) {
                        ProgrammeThumbnail(url: entry.programme.image, uhd: entry.quality.contains("4K")).frame(width: 230)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.programme.title).font(.headline)
                            Text(entry.quality + " • " + ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Play") { playback.startDownloaded(entry, folder: store.folder(for: entry)) { playing = true } }.disabled(playback.loading)
                        Button("Delete", role: .destructive) { store.remove(entry) }
                    }.padding(24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                }
            }.padding(60)
        }.task { store.reconcile() }
        .fullScreenCover(isPresented: $playing, onDismiss: { playback.stop() }) { PlaybackScreen(model: playback) }
        .onDisappear { if !playing { playback.stop() } }
    }
}
