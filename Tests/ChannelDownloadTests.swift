import Foundation

@main struct ChannelDownloadTests {
    @MainActor static func main() async throws {
        let fixture = Data("""
        {"broadcasts":{"elements":[
        {"scheduled_start":"2026-10-20T17:00:00Z","scheduled_end":"2026-10-20T18:00:00Z","episode":{"id":"b0123456","title":"Evening News","available":true,"versions":[{"id":"b0123457","kind":"original"}]}},
        {"scheduled_start":"2026-10-20T16:00:00.000Z","scheduled_end":"2026-10-20T17:00:00.000Z","episode":{"id":"b0123458","title":"Earlier show","available":false,"versions":[{"id":"b0123459"}]}},
        {"scheduled_start":"2026-10-20T18:00:00Z","scheduled_end":"2026-10-20T19:00:00Z","blanked":true,"episode":{"id":"b0123460","title":"Blanked"}},
        {"scheduled_start":"bad-date","scheduled_end":"bad-date","episode":{"id":"b0123461","title":"Broken"}}
        ]}}
        """.utf8)
        let schedule = try DiscoveryAPI.broadcasts(fixture, channelID: "bbcone")
        precondition(schedule.count == 2 && schedule.first?.programme.title == "Earlier show")
        precondition(!schedule[0].available && schedule[1].available)
        precondition(schedule[1].isLive(at: schedule[1].start) && !schedule[1].isLive(at: schedule[1].end))
        precondition(schedule[0].id != schedule[1].id && schedule[1].programme.version == "b0123457")
        let dstDay = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
        let day = DiscoveryAPI.london.startOfDay(for: dstDay)
        precondition(DiscoveryAPI.london.date(byAdding: .day, value: 1, to: day)!.timeIntervalSince(day) == 25 * 3600)
        let scheduleAPI = DiscoveryAPI(fetch: { url in
            precondition(url.query == nil && url.path.contains("/schedule/"), "Use dated schedule, never the current-and-upcoming broadcasts feed")
            if url.path.hasSuffix("2026-10-19") {
                return Data("""
                {"schedule":{"elements":[
                  {"scheduled_start":"2026-10-19T22:30:00Z","scheduled_end":"2026-10-20T05:00:00Z","episode":{"id":"b0123462","title":"Overnight news","status":"unavailable"}},
                  {"scheduled_start":"2026-10-19T18:00:00Z","scheduled_end":"2026-10-19T19:00:00Z","episode":{"id":"b0123463","title":"Outside selected day"}}
                ]}}
                """.utf8)
            }
            precondition(url.path.hasSuffix("2026-10-20"), "Request selected London date")
            return Data("""
            {"schedule":{"elements":[
              {"scheduled_start":"2026-10-20T05:00:00Z","scheduled_end":"2026-10-20T08:30:00Z","episode":{"id":"b0123464","title":"Breakfast","status":"available"}},
              {"scheduled_start":"2026-10-20T18:00:00Z","scheduled_end":"2026-10-20T18:30:00Z","episode":{"id":"b0123465","title":"The One Show"}},
              {"scheduled_start":"2026-10-20T19:00:00Z","scheduled_end":"2026-10-20T20:00:00Z","episode":{"id":"b0123466","title":"Evening programme"}},
              {"scheduled_start":"2026-10-21T05:00:00Z","scheduled_end":"2026-10-21T08:30:00Z","episode":{"id":"b0123467","title":"Tomorrow"}}
            ]}}
            """.utf8)
        })
        let selectedDay = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
        let fullDay = try await scheduleAPI.schedule(channelID: "bbc_one_london", day: selectedDay)
        precondition(fullDay.map { $0.programme.title } == ["Overnight news", "Breakfast", "The One Show", "Evening programme"], "Include past, current, future and overnight shows; exclude other calendar days")
        precondition(!fullDay[0].available && fullDay[1].available, "Read BBC catch-up availability status")
        let suite = "Beeb-feature-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChannelStore(defaults: defaults)
        let one = LiveChannel(id: "bbcone", title: "BBC One"), two = LiveChannel(id: "bbctwo", title: "BBC Two")
        store.channels = [one, two]; store.toggle(one); store.toggle(two); store.move(two, by: -1)
        precondition(store.favouriteIDs == ["bbctwo", "bbcone"])
        store.move(two, by: -1); precondition(store.favouriteIDs == ["bbctwo", "bbcone"])
        precondition(ChannelStore(defaults: defaults).favouriteIDs == ["bbctwo", "bbcone"])
        store.toggle(two); precondition(store.favourites == [one])
        // Rapid tab/date changes exercise cancellation and stale-result handling
        // under -O, the same optimization used by the installed TV app.
        let slowAPI = DiscoveryAPI(fetch: { url in
            try await Task.sleep(nanoseconds: 15_000_000)
            let date = url.lastPathComponent
            return Data("""
            {"schedule":{"elements":[{"scheduled_start":"\(date)T12:00:00Z","scheduled_end":"\(date)T13:00:00Z","episode":{"id":"b0123470","title":"\(date)","status":"available"}}]}}
            """.utf8)
        })
        let loadingStore = ChannelStore(defaults: defaults, api: slowAPI)
        loadingStore.channels = [one, two]
        for _ in 0..<20 {
            let cancelled = Task { await loadingStore.load(day: selectedDay) }
            try await Task.sleep(nanoseconds: 1_000_000)
            cancelled.cancel(); await cancelled.value
            precondition(!loadingStore.loading, "Leaving Live clears loading state")
        }
        let oldLoad = Task { await loadingStore.load(day: selectedDay) }
        try await Task.sleep(nanoseconds: 1_000_000)
        let followingDay = DiscoveryAPI.london.date(byAdding: .day, value: 1, to: selectedDay)!
        await loadingStore.load(day: followingDay)
        await oldLoad.value
        precondition(!loadingStore.loading && loadingStore.schedules.count == 2)
        precondition(loadingStore.schedules.values.flatMap { $0 }.allSatisfy { $0.programme.title == "2026-10-21" }, "A superseded request must never overwrite the selected date")
        let failedAPI = DiscoveryAPI(fetch: { url in
            if url.path.contains("bbcone") { throw BBCError.message("Channel unavailable") }
            return try await slowAPI.fetch(url)
        })
        let partialStore = ChannelStore(defaults: defaults, api: failedAPI); partialStore.channels = [one, two]
        await partialStore.load(day: selectedDay)
        precondition(partialStore.scheduleErrors[one.id] != nil && partialStore.schedules[two.id]?.isEmpty == false, "One channel failure must not stop other schedules")
        let base = URL(string: "https://media.example/master.m3u8?token=abc")!
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
        hd.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160,VIDEO-RANGE=HLG,AUDIO="audio"
        uhd.m3u8
        """
        let media = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\na.m4s\n#EXTINF:4,\nb.m4s\n#EXT-X-ENDLIST\n"
        let package = try await OfflinePackage.build(url: base) { url in
            precondition(url.query?.contains("token=abc") == true, "CDN token propagation")
            if url.path.hasSuffix("master.m3u8") { return Data(master.utf8) }
            precondition(url.path != "/hd.m3u8", "Never download HD when 4K is available")
            return Data(media.utf8)
        }
        precondition(package.height == 2160 && package.videoRange == "HLG")
        precondition(package.playlists.count == 3 && package.media.count == 3)
        for text in package.playlists.values.map({ String(decoding: $0, as: UTF8.self) }) {
            precondition(!text.contains("https://") && !text.contains("token="), "Offline playlists must not require remote media")
        }
        let savedMaster = String(decoding: package.playlists["master.m3u8"]!, as: UTF8.self)
        precondition(savedMaster.contains("AUDIO=\"audio\"") && savedMaster.contains("audio.m3u8"))
        for unsupported in [media.replacingOccurrences(of: "#EXT-X-ENDLIST", with: ""), media + "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n", media + "#EXT-X-BYTERANGE:100@0\n"] {
            do { _ = try await OfflinePackage.build(url: base) { _ in Data(unsupported.utf8) }; fatalError("Unsupported presentation accepted") }
            catch is BBCError { }
        }
        let cancellation = Task {
            try await OfflinePackage.build(url: base) { _ in throw CancellationError() }
        }
        do { _ = try await cancellation.value; fatalError("Cancellation swallowed") } catch is CancellationError { }
        let live = DiscoveryAPI(fetch: { url in
            if url.host == "open.live.bbc.co.uk" {
                let name = url.path.contains("/iptv-all/") ? "best" : "lower"
                return Data("<mediaSelector><media kind=\"video\"><connection transferFormat=\"hls\" href=\"https://media.example/\(name).m3u8\"/></media></mediaSelector>".utf8)
            }
            let height = url.path == "/best.m3u8" ? 2160 : 720
            return Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x\(height),VIDEO-RANGE=HLG\nstream.m3u8\n".utf8)
        })
        let liveSource = try await live.liveSource(one)
        precondition(liveSource.url.path == "/best.m3u8", "Compare quality across all live feed families")
        if CommandLine.arguments.contains("--live-schedule") {
            let today = DiscoveryAPI.london.startOfDay(for: Date())
            let yesterday = DiscoveryAPI.london.date(byAdding: .day, value: -1, to: today)!
            for channel in ["bbc_one_london", "bbc_two_england", "bbc_news24"] {
                let entries = try await DiscoveryAPI().schedule(channelID: channel, day: today)
                let past = entries.filter { $0.end <= Date() }
                precondition(!past.isEmpty, "Live API must include earlier broadcasts")
                print("LIVE \(channel): \(entries.count) broadcasts, \(past.count) already aired, first: \(entries.first!.programme.title)")
            }
            let earlier = try await DiscoveryAPI().schedule(channelID: "bbc_one_london", day: yesterday)
            precondition(!earlier.isEmpty && earlier.allSatisfy { $0.start < today }, "Yesterday must contain past programmes")
            print("LIVE yesterday: \(earlier.count) broadcasts")
        }
        print("PASS: release-mode cancellation/date switching/partial failures, schedule parsing, catch-up availability, DST, persistent favourite order, highest-quality offline video/audio, signed links, unsupported/live rejection and cancellation")
    }
}
