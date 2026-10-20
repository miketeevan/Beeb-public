// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVKit

struct FavouriteChannelsRow: View {
    @EnvironmentObject private var channels: ChannelStore
    @StateObject private var playback = PlaybackModel()
    @State private var managing = false
    @State private var playing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Favourite channels", systemImage: "star.fill").font(.title2).bold()
                Spacer()
                Button("Edit channels") { managing = true }.font(.callout)
            }
            if channels.favourites.isEmpty {
                Button { managing = true } label: {
                    Label("Choose your favourite channels", systemImage: "plus.circle").frame(maxWidth: .infinity, minHeight: 90)
                }.buttonStyle(ProgrammeCardStyle())
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 24) {
                        ForEach(channels.favourites) { channel in
                            FavouriteChannelCard(channel: channel, previewsEnabled: !playing && !managing) {
                                playback.startLive(channel, channels: channels.favourites + channels.channels.filter { !channels.favouriteIDs.contains($0.id) }) { playing = true }
                            }.disabled(playback.loading)
                                .contextMenu {
                                    Button("Move left") { channels.move(channel, by: -1) }
                                    Button("Move right") { channels.move(channel, by: 1) }
                                    Button("Remove favourite") { channels.toggle(channel) }
                                }
                        }
                    }.padding(18)
                }.scrollClipDisabled().padding(.horizontal, -18)
            }
            if let error = playback.error { Text(error).font(.callout).foregroundStyle(.orange) }
            if let error = channels.error, channels.channels.isEmpty { Text(error).font(.callout).foregroundStyle(.orange) }
        }.sheet(isPresented: $managing) { ChannelFavouritesEditor() }
        .fullScreenCover(isPresented: $playing, onDismiss: { playback.stop() }) { PlaybackScreen(model: playback) }
        .onDisappear { if !playing { playback.stop() } }
    }
}
/// Every visible favourite owns a muted player; off-screen cards release their stream.
@MainActor private final class ChannelCardPreview: ObservableObject {
    let player = AVPlayer()
    @Published var loading = false
    @Published var failed = false
    private var generation = UUID()
    private var observation: NSKeyValueObservation?
    func start(_ channel: LiveChannel) async {
        stop(); let token = generation; loading = true; failed = false
        player.isMuted = true
        do {
            let source = try await DiscoveryAPI().liveSource(channel)
            try Task.checkCancellation()
            guard token == generation else { return }
            let item = AVPlayerItem(url: source.url)
            item.preferredForwardBufferDuration = 3
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if status == .readyToPlay { self.loading = false }
                    if status == .failed { self.loading = false; self.failed = true; self.player.pause() }
                }
            }
            player.replaceCurrentItem(with: item); player.play()
        } catch {
            if token == generation { loading = false; failed = !Task.isCancelled }
        }
    }
    func stop() {
        generation = UUID(); observation = nil
        player.pause(); player.replaceCurrentItem(with: nil); loading = false
    }
}
private struct PreviewVisibleKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
private struct FavouriteChannelCard: View {
    let channel: LiveChannel
    let previewsEnabled: Bool
    let watch: () -> Void
    @StateObject private var preview = ChannelCardPreview()
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    private var shouldPlay: Bool { visible && previewsEnabled && phase == .active }
    var body: some View {
        Button(action: watch) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    Color.black
                    InlineChannelPlayer(player: preview.player)
                    if preview.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if preview.failed {
                        VStack(spacing: 8) {
                            Image(systemName: "tv").font(.title2)
                            Text("Preview unavailable").font(.system(size: 17))
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
                    }
                    Text("LIVE").font(.system(size: 16, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5)).padding(10)
                }.frame(width: 320, height: 180).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                Label(channel.title, systemImage: "star.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.cyan).lineLimit(1)
                Text(channel.current?.title ?? "Watch live").font(.system(size: 21)).lineLimit(2).frame(height: 52, alignment: .topLeading)
            }.padding(14).frame(width: 348, alignment: .leading)
        }.buttonStyle(ProgrammeCardStyle())
            .accessibilityLabel(channel.title + ", live preview, " + (channel.current?.title ?? "Watch live"))
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: PreviewVisibleKey.self, value: geometry.frame(in: .global).intersects(UIScreen.main.bounds))
                }
            }
            .onPreferenceChange(PreviewVisibleKey.self) { visible = $0 }
            .task(id: shouldPlay) {
                if shouldPlay { await preview.start(channel) } else { preview.stop() }
            }
            .onDisappear { preview.stop() }
    }
}

struct ChannelFavouritesEditor: View {
    @EnvironmentObject private var channels: ChannelStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Text("Favourite channels").font(.largeTitle).bold(); Spacer(); Button("Done") { dismiss() } }
                Text("Choose channels below. Move favourites left or right to change their order on Home.").font(.callout).foregroundStyle(.secondary)
                ForEach(channels.favourites) { channel in
                    HStack(spacing: 24) {
                        Text(channel.title).font(.headline).frame(width: 350, alignment: .leading)
                        Button("Move left") { channels.move(channel, by: -1) }.disabled(channels.favourites.first?.id == channel.id)
                        Button("Move right") { channels.move(channel, by: 1) }.disabled(channels.favourites.last?.id == channel.id)
                        Button("Remove") { channels.toggle(channel) }
                    }.padding(.vertical, 10)
                }
                Text("All channels").font(.title2).bold()
                if let error = channels.error { Text(error).foregroundStyle(.orange); Button("Retry") { Task { await channels.refreshChannels() } } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330))], spacing: 24) {
                    ForEach(channels.channels) { channel in
                        Button { channels.toggle(channel) } label: {
                            Label(channel.title, systemImage: channels.isFavourite(channel) ? "star.fill" : "star")
                                .frame(maxWidth: .infinity, minHeight: 70)
                        }.tint(channels.isFavourite(channel) ? .cyan : .gray)
                    }
                }
            }.padding(60)
        }.task { if channels.channels.isEmpty { await channels.refreshChannels() } }
    }
}

struct LiveView: View {
    @ObservedObject var library: Library
    @EnvironmentObject private var channels: ChannelStore
    @Environment(\.scenePhase) private var phase
    @StateObject private var playback = PlaybackModel()
    @State private var day = DiscoveryAPI.london.startOfDay(for: Date())
    @State private var selected: ScheduledBroadcast?
    @State private var selectedChannelID: String?
    @State private var catchUp: Programme?
    @State private var playing = false
    @State private var managing = false
    @State private var retry = 0
    @FocusState private var focusedBroadcast: String?
    private let scale: CGFloat = 5.5
    private let rowHeight: CGFloat = 104
    private var endOfDay: Date { DiscoveryAPI.london.date(byAdding: .day, value: 1, to: day)! }
    private var hours: Int { Int(endOfDay.timeIntervalSince(day) / 3600) }
    private var timelineWidth: CGFloat { CGFloat(endOfDay.timeIntervalSince(day) / 60) * scale }
    private var selectedChannel: LiveChannel? { channels.channels.first { $0.id == selectedChannelID } ?? channels.channels.first }
    private var broadcasts: [ScheduledBroadcast] { channels.schedules.values.flatMap { $0 } }
    private var guideChannels: [LiveChannel] {
        channels.favourites + channels.channels.filter { !channels.favouriteIDs.contains($0.id) }
    }
    private var dayLabel: String {
        if DiscoveryAPI.london.isDateInToday(day) { return "Today" }
        let format = DateFormatter(); format.timeZone = DiscoveryAPI.london.timeZone; format.dateFormat = "EEEE d MMM"
        return format.string(from: day)
    }
    var body: some View {
        GeometryReader { viewport in
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                Text("Live & catch-up").font(.title2).bold()
                Spacer()
                Button { changeDay(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
                    .disabled(day <= DiscoveryAPI.london.startOfDay(for: Date().addingTimeInterval(-7 * 86400)))
                Text(dayLabel).font(.system(size: 23, weight: .semibold)).frame(width: 260)
                Button { changeDay(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next day")
                    .disabled(day >= DiscoveryAPI.london.startOfDay(for: Date().addingTimeInterval(7 * 86400)))
                Button("Today") { day = DiscoveryAPI.london.startOfDay(for: Date()); selected = nil }
                Button { managing = true } label: { Image(systemName: "star") }.accessibilityLabel("Edit favourite channels")
            }.font(.system(size: 23)).buttonStyle(GuideActionStyle()).frame(height: 58)
            hero
            if let error = channels.error, channels.channels.isEmpty { HStack { Text(error).foregroundStyle(.orange); Button("Retry") { retry += 1 } } }
            guide.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if channels.loading { ProgressView().scaleEffect(0.65).padding(10).allowsHitTesting(false) }
                }
        }.padding(.horizontal, 24).padding(.top, 8)
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
        .task(id: "\(day.timeIntervalSince1970)-\(retry)-\(phase)") {
            guard phase == .active else { return }
            await channels.load(day: day)
            if selectedChannelID == nil { selectedChannelID = guideChannels.first?.id }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                await channels.refreshChannels()
                await channels.load(day: day)
            }
        }
        .task(id: "\(selectedChannel?.id ?? "")-\(playing)-\(catchUp?.id ?? "")-\(phase)") {
            guard phase == .active, !playing, catchUp == nil, let channel = selectedChannel else { return }
            playback.stop()
            do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
            playback.player.isMuted = true
            playback.startLive(channel) { }
        }
        .onChange(of: focusedBroadcast) { _, id in
            if let show = broadcasts.first(where: { $0.id == id }) { selected = show; selectedChannelID = show.channelID }
        }
        .fullScreenCover(isPresented: $playing, onDismiss: { playback.stop(); playback.player.isMuted = true }) { PlaybackScreen(model: playback) }
        .sheet(item: $catchUp) { DetailView(programme: $0, library: library) }
        .sheet(isPresented: $managing) { ChannelFavouritesEditor() }
        .onDisappear { if !playing { playback.stop() } }
        .onChange(of: phase) { _, value in if value != .active { playback.stop() } }
    }
    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 20) {
                    Text(selectedChannel?.title ?? "Channels").font(.system(size: 24, weight: .semibold)).foregroundStyle(.cyan)
                    if let channel = selectedChannel {
                        Button { channels.toggle(channel) } label: { Image(systemName: channels.isFavourite(channel) ? "star.fill" : "star") }
                            .accessibilityLabel(channels.isFavourite(channel) ? "Remove favourite channel" : "Favourite channel")
                    }
                    Spacer()
                    if let show = selected {
                        Text(show.start.formatted(date: .omitted, time: .shortened) + " – " + show.end.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 21)).foregroundStyle(.secondary)
                    }
                }
                Text(selected?.programme.title ?? selectedChannel?.current?.title ?? "Choose a channel")
                    .font(.system(size: 28, weight: .bold)).lineLimit(1)
                Text(selected?.programme.summary ?? selectedChannel?.current?.subtitle ?? "Browse the schedule or select a channel to watch live.")
                    .font(.system(size: 21)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 24) {
                    if let show = selected, show.start < Date(), !show.isLive(at: Date()) {
                        Button(show.available ? "Watch from start" : "Check catch-up") { openCatchUp(show) }
                    }
                    Button("Watch live") { watchLive() }.disabled(selectedChannel == nil)
                }.font(.system(size: 22))
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    Color.black
                    InlineChannelPlayer(player: playback.player)
                    if playback.loading { ProgressView() }
                    if let error = playback.error { Text(error).font(.system(size: 16)).multilineTextAlignment(.center).padding(12) }
                }.frame(width: 288, height: 162).clipShape(RoundedRectangle(cornerRadius: 10))
                Text("LIVE PREVIEW • \(selectedChannel?.title ?? "")").font(.system(size: 14, weight: .semibold)).foregroundStyle(.cyan)
            }
        }.buttonStyle(GuideActionStyle()).padding(.horizontal, 18).padding(.vertical, 12).frame(height: 210)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }
    private var guide: some View {
        GeometryReader { viewport in
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Text("CHANNELS").font(.caption).bold().foregroundStyle(.cyan).frame(width: 230, height: 52, alignment: .leading)
                    ForEach(guideChannels) { channel in
                        Button { selectedChannelID = channel.id; selected = nil; watchLive(channel) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: channels.isFavourite(channel) ? "star.fill" : "tv").foregroundStyle(.cyan)
                                Text(channel.title).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.leading).lineLimit(3)
                            }.padding(16).frame(width: 220, height: rowHeight - 8, alignment: .leading)
                        }.buttonStyle(ProgrammeCardStyle()).padding(.trailing, 10).frame(height: rowHeight)
                    }
                }.frame(width: 230)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 0) {
                                ForEach(0..<hours, id: \.self) { hour in
                                    Text(day.addingTimeInterval(Double(hour) * 3600).formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 21, weight: .semibold)).frame(width: 60 * scale, height: 52, alignment: .leading).id("hour-\(hour)")
                                }
                            }
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) { ForEach(guideChannels) { channel in scheduleRow(channel) } }
                                TimelineView(.periodic(from: .now, by: 60)) { clock in
                                    if clock.date >= day && clock.date < endOfDay {
                                        Rectangle().fill(.cyan).frame(width: 3, height: CGFloat(guideChannels.count) * rowHeight)
                                            .offset(x: CGFloat(clock.date.timeIntervalSince(day) / 60) * scale)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
                        }.frame(width: timelineWidth, alignment: .leading)
                    }.frame(width: max(0, viewport.size.width - 230))
                    .task(id: day) {
                        let hour = DiscoveryAPI.london.isDateInToday(day) ? max(0, Int(Date().timeIntervalSince(day) / 3600) - 1) : 6
                        proxy.scrollTo("hour-\(hour)", anchor: .leading)
                    }
                }
            }.frame(width: viewport.size.width, alignment: .topLeading)
        }.frame(width: viewport.size.width, height: viewport.size.height)
        }.background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
    private func scheduleRow(_ channel: LiveChannel) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.02))
            if let entries = channels.schedules[channel.id], !entries.isEmpty {
                ForEach(entries.filter { $0.end > day && $0.start < endOfDay }) { show in
                    let start = max(show.start, day), end = min(show.end, endOfDay)
                    let width = max(1, CGFloat(end.timeIntervalSince(start) / 60) * scale - 6)
                    Button {
                        selected = show; selectedChannelID = channel.id
                        if show.isLive(at: Date()) { watchLive(channel) }
                        else if show.start < Date() { openCatchUp(show) }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(show.start.formatted(date: .omitted, time: .shortened) + (show.isLive(at: Date()) ? " • LIVE" : ""))
                                .font(.system(size: 19, weight: .semibold)).foregroundStyle(.cyan).lineLimit(1)
                            Text(show.programme.title).font(.system(size: 21, weight: .semibold)).lineLimit(2)
                        }.padding(.horizontal, min(14, width / 6)).frame(width: width, height: rowHeight - 10, alignment: .leading)
                            .background(show.isLive(at: Date()) ? Color.cyan.opacity(0.13) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(show.isLive(at: Date()) ? .cyan.opacity(0.7) : .white.opacity(0.12), lineWidth: 2) }
                            .clipped()
                    }.buttonStyle(ProgrammeCardStyle()).focused($focusedBroadcast, equals: show.id)
                        .offset(x: CGFloat(start.timeIntervalSince(day) / 60) * scale)
                        .accessibilityLabel(show.programme.title + (show.isLive(at: Date()) ? ", watch live" : show.end < Date() ? ", catch-up" : ", upcoming"))
                }
            } else {
                Text(channels.scheduleErrors[channel.id] != nil ? "Schedule unavailable • select channel to watch live" : channels.loading ? "Loading schedule…" : "No programmes listed")
                    .font(.callout).foregroundStyle(.secondary).padding(.leading, 18).frame(width: 1000, alignment: .leading)
            }
        }.frame(width: timelineWidth, height: rowHeight).clipped()
    }
    private func changeDay(_ offset: Int) { day = DiscoveryAPI.london.date(byAdding: .day, value: offset, to: day)!; selected = nil }
    private func watchLive(_ channel: LiveChannel? = nil) {
        guard let channel = channel ?? selectedChannel else { return }
        playing = true
        playback.player.isMuted = false
        playback.startLive(channel, channels: guideChannels) { }
    }
    private func openCatchUp(_ show: ScheduledBroadcast) { playback.stop(); catchUp = show.programme }
}
private struct InlineChannelPlayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PreviewSurface { let view = PreviewSurface(); view.layerPlayer.player = player; return view }
    func updateUIView(_ view: PreviewSurface, context: Context) { view.layerPlayer.player = player }
}
private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct GuideActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GuideActionSurface(label: configuration.label, pressed: configuration.isPressed)
    }
}
private struct GuideActionSurface<Content: View>: View {
    let label: Content
    let pressed: Bool
    @Environment(\.isFocused) private var focused
    func bodyContent() -> some View {
        label.font(.system(size: 22, weight: .medium)).padding(.horizontal, 16).frame(height: 42)
            .foregroundStyle(focused ? Color.black : Color.white)
            .background(focused ? Color.cyan : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            .opacity(pressed ? 0.7 : 1).focusEffectDisabled()
    }
    var body: some View { bodyContent() }
}
