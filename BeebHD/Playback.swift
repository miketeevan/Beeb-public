// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVKit
import UIKit.UIGestureRecognizerSubclass

@MainActor private struct PlaybackTracking {
    let history: WatchHistory
    let episode: CatalogueEpisode
    let show: CatalogueShow?
    let next: CatalogueEpisode?
    let resumePosition: Double
}

@MainActor final class PlaybackModel: ObservableObject {
    @Published var loading = false
    @Published var status = "Ready to play."
    @Published var error: String?
    @Published var qualityBadge: String?
    @Published var activeSkip: SkipMarker?
    @Published private(set) var liveChannel: LiveChannel?
    private var liveChannels = [LiveChannel]()
    private var skipMarkers = [SkipMarker]()
    private var extrasTasks = [Task<Void, Never>]()
    private var subtitleBridge: LocalHLSServer?
    private var clockObserver: Any?
    let player = AVPlayer()
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private var failedToEndObserver: NSObjectProtocol?
    private var endedObserver: NSObjectProtocol?
    private var tracking: PlaybackTracking?
    private let uhdAccess = UHDPlaybackAccess()
    private var offlineBridge: LocalHLSServer?
    private let extrasAPI: PlaybackExtrasAPI
    private let sourceResolver: ((Programme, PlaybackQuality) async throws -> PlaybackSource)?
    init(sourceResolver: ((Programme, PlaybackQuality) async throws -> PlaybackSource)? = nil, extrasAPI: PlaybackExtrasAPI = PlaybackExtrasAPI()) { self.sourceResolver = sourceResolver; self.extrasAPI = extrasAPI }
    func start(_ programme: Programme, require1080: Bool = false, quality: PlaybackQuality = .automatic, history: WatchHistory? = nil, show: CatalogueShow? = nil, restart: Bool = false, ready: @escaping () -> Void) {
        let episode = show?.episodes.first { $0.id == programme.id } ?? CatalogueEpisode(programme: programme, subtitle: programme.episodeSubtitle ?? programme.title, duration: "", sliceID: "episodes", seriesTitle: "Episodes")
        let next = show.flatMap { EpisodeSequence.next(after: episode, in: $0) }
        let context = history.map { PlaybackTracking(history: $0, episode: episode, show: show, next: next, resumePosition: restart ? 0 : $0.resumePosition(for: programme.id)) }
        begin(programme: programme, tracking: context, title: programme.showTitle ?? programme.title, subtitle: programme.episodeSubtitle ?? "", minimumHeight: quality == .uhd ? 2160 : (quality == .hd && require1080 ? 1080 : 0), ready: ready) {
            if let sourceResolver = self.sourceResolver { return try await sourceResolver(programme, quality) }
            if quality == .automatic {
                return try await PlaybackPolicy.bestSource(uhd: {
                    if UHDIdentityVault.isConfigured {
                        do { return try await self.uhdAccess.source(for: programme) }
                        catch is CancellationError { throw CancellationError() }
                        catch { try Task.checkCancellation() }
                    }
                    return try await UHDService().source(for: programme)
                }, hd: { try await BBCService().source(for: programme, require1080: false) })
            }
            if quality == .uhd {
                if UHDIdentityVault.isConfigured { return try await self.uhdAccess.source(for: programme) }
                return try await UHDService().source(for: programme)
            }
            return try await BBCService().source(for: programme, require1080: require1080)
        }
    }
    func startLive(_ channel: LiveChannel, channels: [LiveChannel] = [], ready: @escaping () -> Void) {
        begin(title: channel.current?.title ?? channel.title, subtitle: channel.title + " • Live", minimumHeight: 0, ready: ready) { try await DiscoveryAPI().liveSource(channel) }
        liveChannel = channel
        liveChannels = channels
    }
    var canSwitchChannels: Bool { liveChannel != nil && liveChannels.count > 1 }
    func changeChannel(by offset: Int) {
        guard let channel = liveChannel, let index = liveChannels.firstIndex(where: { $0.id == channel.id }), canSwitchChannels else { return }
        let list = liveChannels
        let next = (index + offset % list.count + list.count) % list.count
        startLive(list[next], channels: list) { }
    }
    func startDownloaded(_ download: OfflineDownload, folder: URL, ready: @escaping () -> Void) {
        begin(title: download.programme.showTitle ?? download.programme.title, subtitle: "Downloaded • " + download.quality, minimumHeight: 0, ready: ready) {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let resources = Dictionary(uniqueKeysWithValues: files.filter { $0.lastPathComponent != "download.json" }.map { ("/" + $0.lastPathComponent, $0) })
            let bridge = LocalHLSServer(); self.offlineBridge = bridge
            let url = try await bridge.start(playlists: [:], media: resources)
            try Task.checkCancellation()
            return PlaybackSource(url: url, requested1080: false, videoRange: download.videoRange)
        }
    }
    static func metadata(title: String, subtitle: String) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ text: String) -> AVMetadataItem {
            let value = AVMutableMetadataItem(); value.identifier = identifier; value.value = text as NSString; value.extendedLanguageTag = "und"; return value
        }
        return [item(.commonIdentifierTitle, title), item(.iTunesMetadataTrackSubTitle, subtitle)]
    }
    private func begin(programme: Programme? = nil, tracking context: PlaybackTracking? = nil, title: String, subtitle: String, minimumHeight: Int, ready: @escaping () -> Void, resolve: @escaping () async throws -> PlaybackSource) {
        stop(); error = nil; loading = true; status = "Finding the best available stream…"
        let id = generation
        operation = Task { [self] in
            defer { if generation == id { loading = false } }
            do {
                let source = try await resolve(); try Task.checkCancellation()
                guard id == generation else { return }
                let playbackURL = await nativeSubtitleURL(for: source)
                try Task.checkCancellation()
                guard id == generation else { return }
                let item = AVPlayerItem(url: playbackURL)
                item.externalMetadata = Self.metadata(title: title, subtitle: subtitle)
                failedToEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                    let failure = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                    let message = failure?.localizedDescription ?? "The stream could not continue. Close and retry."
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id else { return }
                        self.checkpoint(); self.error = message; self.status = "Playback stopped."; self.player.pause()
                    }
                }
                player.replaceCurrentItem(with: item)
                prepareExtras(programme: programme, versionID: source.versionID, item: item, generation: id)
                clockObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id else { return }
                        self.updateTimedControls(at: time.seconds)
                    }
                }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                if let context, context.resumePosition > 0 {
                    status = "Resuming episode…"
                    var waited = 0
                    while item.status != .readyToPlay {
                        if item.status == .failed { throw item.error ?? BBCError.message("Unable to resume this episode.") }
                        guard waited < 300 else { throw BBCError.message("Timed out preparing the saved position. Close and retry.") }
                        try await Task.sleep(nanoseconds: 100_000_000); waited += 1
                    }
                    let duration = item.duration.seconds
                    let position = duration.isFinite && duration > 0 ? min(context.resumePosition, max(0, duration - 2)) : context.resumePosition
                    let sought = await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    try Task.checkCancellation()
                    guard generation == id else { return }
                    guard sought else { throw BBCError.message("Unable to seek to the saved position. Close and retry.") }
                }
                tracking = context
                endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id else { return }
                        self.checkpoint(ended: true)
                    }
                }
                status = "Starting playback…"
                let requiredHeight = max(minimumHeight, source.requestedHeight ?? 0)
                ready(); player.play()
                monitor = Task {
                    var seconds = 0
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                        seconds += 1
                        if seconds % 5 == 0 { checkpoint() }
                        if item.status == .failed { error = item.error?.localizedDescription ?? "Playback failed. Close and retry."; player.pause(); return }
                        let size = item.presentationSize
                        if size.height > 0 {
                            let h = Int(size.height.rounded()), w = Int(size.width.rounded())
                            qualityBadge = PlaybackPolicy.badge(height: h, videoRange: source.videoRange)
                            status = player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "Buffering…" : "Playing"
                            if requiredHeight > 0 && h < requiredHeight { error = "This stream is \(w) × \(h), below your \(requiredHeight)p requirement."; player.pause(); return }
                        } else if seconds >= 40 { error = "No video arrived within 40 seconds. Close and retry."; player.pause(); return }
                    }
                }
            } catch { if !Task.isCancelled, generation == id { self.error = error.localizedDescription; status = "Unable to start playback." } }
        }
    }
    private func nativeSubtitleURL(for source: PlaybackSource) async -> URL {
        guard let version = source.versionID else { return source.url }
        do {
            let cues = try await extrasAPI.subtitles(versionID: version)
            guard !cues.isEmpty else { return source.url }
            let raw = try await BBCService().fetch(source.url)
            let master = String(decoding: raw, as: UTF8.self)
            guard master.hasPrefix("#EXTM3U") else { return source.url }
            // Existing HLS subtitle renditions already work with the single native control.
            if master.contains("TYPE=SUBTITLES") { return source.url }
            var media = master, mediaBase = source.url
            if master.contains("#EXT-X-STREAM-INF:") {
                let lines = master.components(separatedBy: .newlines)
                guard let index = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }), index + 1 < lines.count,
                      let url = HLSSubtitles.resolve(lines[index + 1], base: source.url) else { return source.url }
                mediaBase = url
                media = String(decoding: try await BBCService().fetch(url), as: UTF8.self)
            }
            var origin: UInt64 = 0
            if !media.contains("#EXT-X-MAP:") {
                guard let segment = media.components(separatedBy: .newlines).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                      let url = HLSSubtitles.resolve(segment, base: mediaBase),
                      let pts = HLSSubtitles.firstVideoPTS(try await BBCService().fetch(url)) else { return source.url }
                origin = pts
            }
            let assets = try HLSSubtitles.assets(cues: cues, duration: HLSSubtitles.duration(media), master: master, base: source.url, mpegTimestamp: origin)
            try Task.checkCancellation()
            let bridge = LocalHLSServer(); subtitleBridge = bridge
            return try await bridge.start(playlists: assets)
        } catch { return source.url } // Caption failure must never discard an already selected UHD stream.
    }
    private func prepareExtras(programme: Programme?, versionID: String?, item: AVPlayerItem, generation id: UUID) {
        let api = extrasAPI
        if let programme, let versionID {
            extrasTasks.append(Task { [weak self] in
                let markers = (try? await api.markers(episodeID: programme.id, versionID: versionID)) ?? []
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.skipMarkers = markers; self.updateTimedControls(at: self.player.currentTime().seconds)
            })
        }
    }

    func updateTimedControls(at time: Double) {
        let marker = skipMarkers.first { $0.contains(time) }
        if activeSkip != marker { activeSkip = marker }
    }
    func skip(_ marker: SkipMarker) {
        guard marker == activeSkip, marker.contains(player.currentTime().seconds) else { return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        guard !duration.isFinite || marker.end < duration else { return }
        player.seek(to: CMTime(seconds: marker.end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        activeSkip = nil
    }
    func checkpoint(ended: Bool = false) {
        guard let tracking, let item = player.currentItem else { return }
        tracking.history.update(episode: tracking.episode, show: tracking.show, next: tracking.next,
                                position: player.currentTime().seconds, duration: item.duration.seconds, ended: ended)
    }
    func stop() {
        checkpoint(); tracking = nil; liveChannel = nil; liveChannels = []
        extrasTasks.forEach { $0.cancel() }; extrasTasks = []
        if let clockObserver { player.removeTimeObserver(clockObserver) }; clockObserver = nil
        skipMarkers = []; activeSkip = nil
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }; endedObserver = nil
        if let failedToEndObserver { NotificationCenter.default.removeObserver(failedToEndObserver) }; failedToEndObserver = nil
        generation = UUID(); operation?.cancel(); monitor?.cancel(); operation = nil; monitor = nil
        subtitleBridge?.stop(); subtitleBridge = nil
        uhdAccess.stop()
        offlineBridge?.stop(); offlineBridge = nil
        player.pause(); player.replaceCurrentItem(with: nil); loading = false; qualityBadge = nil
    }
}
struct NativePlayer: UIViewControllerRepresentable {
    @ObservedObject var model: PlaybackModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = model.player; controller.delegate = context.coordinator
        controller.showsPlaybackControls = true; controller.transportBarIncludesTitleView = true
        context.coordinator.attach(to: controller, model: model)
        let label = context.coordinator.label
        label.text = model.qualityBadge; label.isHidden = model.qualityBadge == nil; label.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = controller.contentOverlayView {
            overlay.addSubview(label)
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 36), label.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -48)])
        }
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.refreshChannelHint()
        coordinator.label.text = model.qualityBadge; coordinator.label.isHidden = model.qualityBadge == nil
        if coordinator.marker != model.activeSkip {
            coordinator.marker = model.activeSkip
            controller.contextualActions = model.activeSkip.map { marker in
                [UIAction(title: marker.title) { [weak model] _ in Task { @MainActor in model?.skip(marker) } }]
            } ?? []
        }
        controller.transportBarCustomMenuItems = []
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        weak var model: PlaybackModel?
        private var controlsVisible = false
        private var channelMode = false
        private let channelHint = QualityBadgeLabel()
        func attach(to controller: AVPlayerViewController, model: PlaybackModel) {
            self.model = model
            for type: UIPress.PressType in [.downArrow, .upArrow, .leftArrow, .rightArrow, .menu] {
                let tap = ChannelRemoteGesture(target: self, action: #selector(remotePressed(_:)))
                tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
                tap.allowedTouchTypes = []
                tap.delegate = self
                controller.view.addGestureRecognizer(tap)
            }
            channelHint.font = .systemFont(ofSize: 26, weight: .semibold)
            channelHint.textColor = .white
            channelHint.backgroundColor = UIColor.black.withAlphaComponent(0.85)
            channelHint.layer.cornerRadius = 12
            channelHint.clipsToBounds = true
            channelHint.isHidden = true
            channelHint.isUserInteractionEnabled = false
            channelHint.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(channelHint)
            NSLayoutConstraint.activate([
                channelHint.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
                channelHint.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -55)
            ])
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            guard model?.canSwitchChannels == true else { return false }
            // Let AVKit handle the first Down and normal seeking/focus movement.
            if press.type == .downArrow { return controlsVisible || channelMode }
            return channelMode
        }
        @objc private func remotePressed(_ gesture: ChannelRemoteGesture) {
            guard let value = gesture.allowedPressTypes.first, let type = UIPress.PressType(rawValue: value.intValue) else { return }
            switch type {
            case .downArrow: channelMode = true
            case .rightArrow: model?.changeChannel(by: 1)
            case .leftArrow: model?.changeChannel(by: -1)
            case .upArrow, .menu: channelMode = false
            default: break
            }
            refreshChannelHint()
        }
        func refreshChannelHint() {
            if model?.canSwitchChannels != true { channelMode = false }
            channelHint.isHidden = !channelMode
            channelHint.text = "← Channel down     " + (model?.liveChannel?.title ?? "") + "     Channel up →   •   ↑ Controls"
        }
        var marker: SkipMarker?
        let label: UILabel = {
            let label = QualityBadgeLabel(); label.font = .systemFont(ofSize: 24, weight: .bold)
            label.textColor = .white; label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            label.layer.cornerRadius = 5; label.layer.borderWidth = 1.5; label.layer.borderColor = UIColor.white.cgColor
            label.clipsToBounds = true; label.alpha = 0
            label.isUserInteractionEnabled = false
            return label
        }()
        @objc(playerViewController:willTransitionToVisibilityOfTransportBar:withAnimationCoordinator:)
        func playerViewController(_ playerViewController: AVPlayerViewController, willTransitionToVisibilityOfTransportBar visible: Bool, with coordinator: AVPlayerViewControllerAnimationCoordinator) {
            controlsVisible = visible
            coordinator.addCoordinatedAnimations({ self.label.alpha = visible ? 1 : 0; playerViewController.contentOverlayView?.layoutIfNeeded() }, completion: nil)
        }
    }
}
struct PlaybackScreen: View {
    @ObservedObject var model: PlaybackModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            NativePlayer(model: model).ignoresSafeArea()
            if let error = model.error {
                VStack(spacing: 24) {
                    Text(error).foregroundStyle(.orange).frame(maxWidth: 850)
                    Button("Close player") { dismiss() }
                }.padding(35).background(.black.opacity(0.9)).cornerRadius(16)
            }
        }.onExitCommand { dismiss() }
        .onChange(of: phase) { _, value in if value != .active { model.checkpoint() } }
    }
}

/// Insets are part of the intrinsic size, so the rectangular quality mark stays compact.
private final class QualityBadgeLabel: UILabel {
    private let insets = UIEdgeInsets(top: 7, left: 13, bottom: 7, right: 13)
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
}

/// Claim channel commands before AVKit's directional focus/seek recognizers.
private final class ChannelRemoteGesture: UIGestureRecognizer {
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .recognized
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) { }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) { state = .cancelled }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
