// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

struct ScheduledBroadcast: Identifiable, Hashable {
    let id: String
    let channelID: String
    let start: Date
    let end: Date
    let programme: Programme
    let available: Bool
    func isLive(at now: Date) -> Bool { start <= now && now < end }
}
extension DiscoveryAPI {
    static var london: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/London")!
        return value
    }
    static func broadcasts(_ data: Data, channelID: String) throws -> [ScheduledBroadcast] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let body = (root?["schedule"] ?? root?["broadcasts"]) as? [String: Any], let elements = body["elements"] as? [[String: Any]] else {
            throw BBCError.message("This channel's schedule is unavailable.")
        }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? { (value as? String).flatMap { fractional.date(from: $0) ?? plain.date(from: $0) } }
        return elements.compactMap { item in
            guard item["blanked"] as? Bool != true, let start = date(item["scheduled_start"]), let end = date(item["scheduled_end"]), end > start,
                  let episode = item["episode"] as? [String: Any], let parsed = try? CatalogueAPI.episode(episode) else { return nil }
            let available = episode["available"] as? Bool
                ?? (episode["status"] as? String).map { $0 == "available" }
                ?? !(episode["versions"] as? [[String: Any]] ?? []).isEmpty
            return ScheduledBroadcast(id: channelID + "-" + String(start.timeIntervalSince1970), channelID: channelID,
                                      start: start, end: end, programme: parsed.programme, available: available)
        }.sorted { $0.start < $1.start }
    }
    func schedule(channelID: String, day: Date) async throws -> [ScheduledBroadcast] {
        guard channelID.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil else { throw BBCError.message("Invalid channel.") }
        let format = DateFormatter(); format.calendar = Self.london; format.timeZone = Self.london.timeZone; format.dateFormat = "yyyy-MM-dd"
        let start = Self.london.startOfDay(for: day)
        let end = Self.london.date(byAdding: .day, value: 1, to: start)!
        let previous = Self.london.date(byAdding: .day, value: -1, to: start)!
        func dated(_ date: Date) async throws -> [ScheduledBroadcast] {
            let url = URL(string: "https://ibl.api.bbc.co.uk/ibl/v1/channels/\(channelID)/schedule/\(format.string(from: date))")!
            return try Self.broadcasts(await fetch(url), channelID: channelID)
        }
        // BBC's broadcast day crosses midnight. The preceding schedule supplies
        // the overnight programmes belonging to this London calendar day.
        let currentDay = try await dated(start)
        try Task.checkCancellation()
        let previousDay: [ScheduledBroadcast]
        do { previousDay = try await dated(previous) }
        catch is CancellationError { throw CancellationError() }
        catch { previousDay = [] }
        let entries = currentDay + previousDay
        try Task.checkCancellation()
        var seen = Set<String>()
        return entries.filter { $0.end > start && $0.start < end && seen.insert($0.id).inserted }
            .sorted { $0.start < $1.start }
    }
}

@MainActor final class ChannelStore: ObservableObject {
    @Published var channels: [LiveChannel] = []
    @Published private(set) var favouriteIDs: [String]
    @Published var schedules: [String: [ScheduledBroadcast]] = [:]
    @Published var scheduleErrors: [String: String] = [:]
    @Published var error: String?
    @Published var loading = false
    private let defaults: UserDefaults
    private let api: DiscoveryAPI
    private var revision = UUID()
    private var loadedDay: Date?
    init(defaults: UserDefaults = .standard, api: DiscoveryAPI = DiscoveryAPI()) {
        self.defaults = defaults; self.api = api
        favouriteIDs = defaults.stringArray(forKey: "favouriteChannels-v1") ?? []
        if let data = defaults.data(forKey: "channelList-v1"), let cached = try? JSONDecoder().decode([LiveChannel].self, from: data) { channels = cached }
    }
    var favourites: [LiveChannel] { favouriteIDs.compactMap { id in channels.first { $0.id == id } } }
    func isFavourite(_ channel: LiveChannel) -> Bool { favouriteIDs.contains(channel.id) }
    func toggle(_ channel: LiveChannel) {
        if isFavourite(channel) { favouriteIDs.removeAll { $0 == channel.id } } else { favouriteIDs.append(channel.id) }
        persist()
    }
    func move(_ channel: LiveChannel, by offset: Int) {
        guard let index = favouriteIDs.firstIndex(of: channel.id), favouriteIDs.indices.contains(index + offset) else { return }
        favouriteIDs.swapAt(index, index + offset); persist()
    }
    private func persist() { defaults.set(favouriteIDs, forKey: "favouriteChannels-v1") }
    func refreshChannels() async {
        do {
            let list = try await api.channels()
            let updated = await api.nowPlaying(list)
            try Task.checkCancellation(); channels = updated; error = nil
            defaults.set(try? JSONEncoder().encode(updated), forKey: "channelList-v1")
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func load(day: Date) async {
        let token = UUID(); revision = token; loading = true
        defer { if token == revision { loading = false } }
        if loadedDay != day { schedules = [:]; scheduleErrors = [:]; loadedDay = day }
        if channels.isEmpty { await refreshChannels() }
        // Load incrementally without nested task groups. Cancelling or changing
        // dates cannot leave child tasks delivering results into an old load.
        let list = channels
        for channel in list {
            guard !Task.isCancelled, token == revision else { return }
            do {
                let entries = try await api.schedule(channelID: channel.id, day: day)
                try Task.checkCancellation()
                guard token == revision else { return }
                schedules[channel.id] = entries; scheduleErrors[channel.id] = nil
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, token == revision else { return }
                if schedules[channel.id] == nil { schedules[channel.id] = [] }
                scheduleErrors[channel.id] = error.localizedDescription
            }
        }
    }
}
