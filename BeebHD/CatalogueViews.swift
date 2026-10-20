// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

private enum BeebTab: String, CaseIterable { case home = "Home", live = "Live", browse = "Browse", saved = "Saved", downloads = "Downloads", settings = "Settings" }
struct HomeView: View {
    @StateObject private var catalogue = CatalogueStore()
    @StateObject private var channels = ChannelStore()
    @StateObject private var downloads = DownloadStore()
    @StateObject private var library = Library()
    @StateObject private var history = WatchHistory()
    @State private var tab = BeebTab.home
    @FocusState private var focusedTab: BeebTab?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 30) {
                Image("BeebMark").resizable().scaledToFit().frame(width: 64, height: 64).accessibilityLabel("Beeb")
                HStack(spacing: 14) { ForEach(BeebTab.allCases, id: \.self) { value in BeebTabButton(tab: value, selection: $tab, focus: $focusedTab) } }
                Spacer(minLength: 0)
                if catalogue.loading { ProgressView().accessibilityLabel("Updating homepage") }
            }.padding(.horizontal, 64).padding(.vertical, 18)
            NavigationStack {
                switch tab {
                case .home: DiscoveryHome(catalogue: catalogue, library: library)
                case .browse: BrowseView(catalogue: catalogue, library: library)
                case .live: LiveView(library: library).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                case .downloads: DownloadsView()
                case .saved: SavedProgrammes(catalogue: catalogue, library: library)
                case .settings: SettingsView(catalogue: catalogue)
                }
            }.id(tab)
        }.ignoresSafeArea(.container, edges: tab == .live ? [.horizontal, .bottom] : [])
        .environmentObject(history).environmentObject(channels).environmentObject(downloads).tint(.pink).defaultFocus($focusedTab, .home)
        .task { await catalogue.boot() }
        .task { await channels.refreshChannels() }
        .onChange(of: phase) { _, value in if value == .active { Task { await catalogue.refreshHome() } } }
    }
}
private struct BeebTabButton: View {
    let tab: BeebTab
    @Binding var selection: BeebTab
    let focus: FocusState<BeebTab?>.Binding
    private var focused: Bool { focus.wrappedValue == tab }
    var body: some View {
        Button { selection = tab } label: {
            Text(tab.rawValue).font(.headline).padding(.horizontal, 24).padding(.vertical, 16)
                .foregroundStyle(focused || selection == tab ? .white : .white.opacity(0.7))
                .background(focused ? Color.white.opacity(0.2) : selection == tab ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(BeebTabStyle()).focused(focus, equals: tab).focusEffectDisabled()
            .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}
private struct BeebTabStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
}
private struct BannerRotationKey: Hashable { let index: Int; let count: Int; let paused: Bool }
@MainActor final class HomeState: ObservableObject { @Published var banner = 0 }
struct DiscoveryHome: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @StateObject private var state = HomeState()
    @Environment(\.scenePhase) private var phase
    @FocusState private var bannerFocused: Bool
    @FocusState private var focusedCard: String?
    @State private var visible = false
    private var rotationKey: BannerRotationKey {
        BannerRotationKey(index: state.banner, count: catalogue.home?.features.count ?? 0, paused: !visible || bannerFocused || phase != .active)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                FavouriteChannelsRow()
                if let error = catalogue.error { Text(error).foregroundStyle(.orange).font(.callout) }
                if catalogue.home == nil { ContinueWatchingRow(catalogue: catalogue, library: library) }
                if let feed = catalogue.home {
                    if !feed.features.isEmpty {
                        let index = min(state.banner, feed.features.count - 1)
                        let feature = feed.features[index]
                        NavigationLink { CatalogueShowView(show: feature.show, catalogue: catalogue, library: library) } label: {
                            ZStack(alignment: .bottomLeading) {
                                Color.clear.overlay {
                                    GeometryReader { geometry in
                                        AsyncImage(url: feature.image) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.gray.opacity(0.15)) }
                                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                                    }
                                }
                                LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("NEW & TRENDING").font(.caption).tracking(4).foregroundStyle(.pink)
                                    Text(feature.headline).font(.system(size: 48, weight: .bold)).lineLimit(2)
                                    Text(feature.synopsis).font(.title3).lineLimit(2).frame(maxWidth: 1000, alignment: .leading)
                                    Label("Explore programme", systemImage: "play.fill").font(.headline)
                                }.padding(38)
                            }.frame(height: 530).cornerRadius(18)
                        }.buttonStyle(ProgrammeCardStyle()).focused($bannerFocused)
                        HStack(spacing: 26) {
                            Button { state.banner = (index + feed.features.count - 1) % feed.features.count } label: { Image(systemName: "chevron.left") }
                            Text("\(index + 1) / \(feed.features.count)").foregroundStyle(.secondary)
                            Button { state.banner = (index + 1) % feed.features.count } label: { Image(systemName: "chevron.right") }
                            Spacer()
                        }
                    }
                    ContinueWatchingRow(catalogue: catalogue, library: library)
                    ForEach(feed.rows) { row in
                        VStack(alignment: .leading, spacing: 18) {
                            Text(row.title).font(.title2).bold()
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 28) {
                                    ForEach(row.shows) { show in
                                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show).frame(width: 330) }.buttonStyle(ProgrammeCardStyle()).focused($focusedCard, equals: "\(row.id):\(show.id)")
                                    }
                                }.padding(.vertical, 30).padding(.horizontal, 24)
                            }.scrollClipDisabled().padding(.horizontal, -24)
                        }
                    }
                } else if catalogue.loading { ProgressView("Getting the latest programmes…") }
                else { Button("Retry homepage") { Task { await catalogue.refreshHome() } } }
            }.padding(.horizontal, 64).padding(.vertical, 26)
        }.scrollClipDisabled()
        .onAppear { visible = true }
        .task(id: phase) {
            #if DEBUG
            guard phase == .active else { return }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            if ProcessInfo.processInfo.environment["BEEB_UI_PREVIEW"] == "cards" { focusedCard = "preview:preview-0" }
            if ProcessInfo.processInfo.environment["BEEB_UI_PREVIEW"] == "banner-focused" { bannerFocused = true }
            #endif
        }
        .onDisappear { visible = false }
        .onChange(of: rotationKey) { _, _ in recordBannerValidation() }
        .task(id: rotationKey) {
            guard !rotationKey.paused, rotationKey.count > 1 else { return }
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard !Task.isCancelled, visible, !bannerFocused, phase == .active else { return }
            withAnimation(.easeInOut(duration: 0.4)) { state.banner = (state.banner + 1) % rotationKey.count }
        }
    }
    private func recordBannerValidation() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["BEEB_UI_PREVIEW"] != nil else { return }
        let values: [String: Any] = ["index": state.banner, "count": rotationKey.count, "focused": bannerFocused, "visible": visible, "active": phase == .active, "timestamp": Date().timeIntervalSince1970]
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UI-validation.json")
        if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: output, options: .atomic) }
        #endif
    }

}
@MainActor final class BrowseState: ObservableObject { @Published var mode = "Categories" }
struct BrowseView: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @StateObject private var state = BrowseState()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Browse programmes").font(.largeTitle).bold()
                Picker("Browse by", selection: $state.mode) { Text("Categories").tag("Categories"); Text("A–Z").tag("A–Z") }.pickerStyle(.segmented)
                if state.mode == "Categories" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330))], spacing: 28) {
                        ForEach(catalogue.genres) { genre in
                            NavigationLink { ProgrammePage(title: genre.title, category: genre.id, letter: nil, catalogue: catalogue, library: library) } label: {
                                Text(genre.title).font(.title3).frame(maxWidth: .infinity, minHeight: 90).padding(12)
                            }
                        }
                    }
                    if catalogue.genres.isEmpty { Button("Reload categories") { Task { await catalogue.refreshHome() } } }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 24) {
                        ForEach(CatalogueAPI.letters, id: \.self) { letter in
                            NavigationLink { ProgrammePage(title: letter.uppercased(), category: nil, letter: letter, catalogue: catalogue, library: library) } label: {
                                Text(letter.uppercased()).font(.title2).frame(maxWidth: .infinity, minHeight: 75)
                            }
                        }
                    }
                }
                Text("Choose a category or letter. Programme listings load one page at a time; episodes load when you open a programme.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(60)
        }
    }
}
struct ProgrammePage: View {
    let title: String
    let category: String?
    let letter: String?
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @StateObject private var page = PageStore()
    @StateObject private var state = PageState()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(title).font(.largeTitle).bold()
                HStack(spacing: 24) {
                    Button("Previous") { state.page -= 1 }.disabled(state.page <= 1 || page.loading)
                    Text("Page \(state.page) of \(page.totalPages) · \(page.count) programmes").font(.callout)
                    Button("Next") { state.page += 1 }.disabled(state.page >= page.totalPages || page.loading)
                    Spacer()
                }
                if page.loading { ProgressView("Loading programmes…") }
                if let error = page.error { Text(error).foregroundStyle(.orange); Button("Retry") { state.retry += 1 } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 28)], spacing: 30) {
                    ForEach(page.shows) { show in
                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show) }.buttonStyle(ProgrammeCardStyle())
                    }
                }
            }.padding(60)
        }.task(id: "\(state.page)-\(state.retry)") { await page.load(category: category, letter: letter, page: state.page) }
    }
}
@MainActor final class PageState: ObservableObject { @Published var page = 1; @Published var retry = 0 }
/// Give the image a finite proposal before scaledToFill; intrinsic artwork sizes
/// must never determine a row's card width or its focus outline.
struct ProgrammeThumbnail: View {
    let url: URL?
    let uhd: Bool
    var hdr = false
    var body: some View {
        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                        Rectangle().fill(.gray.opacity(0.15)).overlay(Image(systemName: "play.tv").font(.largeTitle))
                    }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) { if uhd { UHDListedBadge(hdr: hdr).padding(10) } }
    }
}
struct ProgrammeCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ProgrammeCardSurface(content: configuration.label, pressed: configuration.isPressed) }
}
private struct ProgrammeCardSurface<Content: View>: View {
    let content: Content
    let pressed: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        content
            .background(focused ? Color.white.opacity(0.16) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? .white : .clear, lineWidth: 3) }
            .scaleEffect(pressed ? 0.99 : focused ? 1.045 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 16, y: 8)
            .animation(.easeOut(duration: 0.15), value: focused)
            .focusEffectDisabled().zIndex(focused ? 1 : 0)
    }
}
struct ShowCard: View {
    let show: CatalogueShow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgrammeThumbnail(url: show.image, uhd: show.uhdListed == true, hdr: show.hdrListed == true)
            Text(show.title).font(.headline).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .topLeading)
            Text(show.expectedEpisodes > 0 ? "\(show.expectedEpisodes) episodes" : "Explore programme")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
@MainActor final class ShowState: ObservableObject {
    @Published var show: CatalogueShow?
    @Published var seriesID = ""
    @Published var selection: Programme?
    @Published var error: String?
    @Published var retry = 0
    @Published var episodePage = 1
}
struct CatalogueShowView: View {
    let show: CatalogueShow
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    @StateObject private var state = ShowState()
    @FocusState private var focusedEpisode: String?
    var current: CatalogueShow { state.show ?? show }
    var orderedSeries: [CatalogueSeries] { EpisodeSequence.orderedSeries(current.series) }
    var selectedEpisodes: [CatalogueEpisode] {
        let group = orderedSeries.first { $0.id == state.seriesID } ?? orderedSeries.first
        return EpisodeSequence.ordered(group?.episodes ?? [])
    }
    var visibleEpisodes: [CatalogueEpisode] { Array(selectedEpisodes.dropFirst((state.episodePage - 1) * 30).prefix(30)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text(current.title).font(.largeTitle).bold(); Spacer()
                    ProgrammeBookmarkButton(show: current, library: library)
                }
                Text(current.summary).font(.title3).foregroundStyle(.secondary)
                if state.show == nil && state.error == nil { ProgressView("Getting series and episodes…") }
                if let error = state.error { Text(error).foregroundStyle(.orange); Button("Retry") { state.retry += 1 } }
                if current.series.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 20) {
                            ForEach(orderedSeries) { series in
                                Button(series.title) { state.seriesID = series.id; state.episodePage = 1 }
                                    .tint((state.seriesID.isEmpty ? orderedSeries.first?.id : state.seriesID) == series.id ? .pink : .gray)
                            }
                        }.padding(.vertical, 30).padding(.horizontal, 24)
                    }.scrollClipDisabled().padding(.horizontal, -24)
                }
                if selectedEpisodes.count > 30 {
                    HStack(spacing: 24) {
                        Button("Previous episodes") { state.episodePage -= 1 }.disabled(state.episodePage <= 1)
                        Text("Episodes \((state.episodePage - 1) * 30 + 1)–\(min(state.episodePage * 30, selectedEpisodes.count))")
                        Button("More episodes") { state.episodePage += 1 }.disabled(state.episodePage * 30 >= selectedEpisodes.count)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 30)], spacing: 30) {
                    ForEach(visibleEpisodes) { episode in
                        Button { state.selection = episode.programme } label: { ProgrammeCard(programme: episode.programme) }.buttonStyle(ProgrammeCardStyle()).focused($focusedEpisode, equals: episode.id)
                    }
                }
                if state.show != nil && selectedEpisodes.isEmpty { Text("No episodes are currently available.").foregroundStyle(.secondary) }
            }.padding(60)
        }.task(id: state.retry) {
            state.error = nil
            do { state.show = try await catalogue.open(show) } catch { if !Task.isCancelled { state.error = error.localizedDescription } }
        }.defaultFocus($focusedEpisode, visibleEpisodes.first?.id)
        .task(id: visibleEpisodes.first?.id) {
            guard let first = visibleEpisodes.first?.id else { return }
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            focusedEpisode = first
        }.sheet(item: $state.selection) { DetailView(programme: $0, show: current, library: library) }
    }
}
struct SavedProgrammes: View {
    @ObservedObject var catalogue: CatalogueStore
    @ObservedObject var library: Library
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Label("Saved programmes", systemImage: "bookmark.fill").font(.largeTitle).bold()
                if let warning = library.migrationWarning { Text(warning).foregroundStyle(.orange).font(.callout) }
                if library.saved.isEmpty { Text("Save a programme to follow all of its series and episodes here.").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330))], spacing: 30) {
                    ForEach(library.saved) { show in
                        NavigationLink { CatalogueShowView(show: show, catalogue: catalogue, library: library) } label: { ShowCard(show: show) }.buttonStyle(ProgrammeCardStyle())
                    }
                }
            }.padding(60)
        }.task { await library.migrate(); await library.refreshArtwork() }
    }
}
struct SettingsView: View {
    @ObservedObject var catalogue: CatalogueStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Settings").font(.largeTitle).bold()
                Text("Playback automatically selects the best available quality, including 4K HDR when available. Live channel quality adapts to the stream BBC supplies.").foregroundStyle(.secondary)
                Button("Refresh homepage") { Task { await catalogue.refreshHome() } }.disabled(catalogue.loading)
                Text("Programme listings load only when you select a category or letter. Series and episodes load when you open a programme. Saved programmes include all their series.")
                if let warning = catalogue.storageWarning { Text(warning).foregroundStyle(.orange) }
                UHDSetupView()
                Text("Beeb 0.8.2 • Custom build 15 • Independent BBC player").font(.caption).foregroundStyle(.secondary)
            }.padding(60)
        }
    }
}
