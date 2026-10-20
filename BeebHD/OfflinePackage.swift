// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A finite HLS presentation, rewritten to flat local names. Only unprotected VOD is cached.
struct OfflinePackage {
    var playlists: [String: Data]
    var media: [String: URL]
    let height: Int
    let videoRange: String?
    static func attribute(_ name: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[:,])" + name + "=\"([^\"]*)\""),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
    static func build(url: URL, fetch: (URL) async throws -> Data) async throws -> OfflinePackage {
        let raw = String(decoding: try await fetch(url), as: UTF8.self)
        guard raw.hasPrefix("#EXTM3U") else { throw BBCError.message("This stream is not a downloadable HLS programme.") }
        var package = OfflinePackage(playlists: [:], media: [:], height: 0, videoRange: nil)
        if let best = BBCService.variants(raw, base: url).first {
            package = OfflinePackage(playlists: [:], media: [:], height: best.height, videoRange: best.videoRange)
            let lines = raw.components(separatedBy: .newlines)
            guard let streamIndex = lines.indices.first(where: { lines[$0].hasPrefix("#EXT-X-STREAM-INF:") && $0 + 1 < lines.count && BBCService.resolve(lines[$0 + 1], base: url) == best.url }) else { throw BBCError.message("The best stream could not be selected.") }
            let stream = lines[streamIndex]
            var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
            for type in ["AUDIO", "SUBTITLES"] {
                guard let group = attribute(type, in: stream) else { continue }
                let renditions = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=\(type),") && attribute("GROUP-ID", in: $0) == group }
                // Keep one English/default rendition per group, avoiding every language and duplicate audio.
                let rendition = renditions.first { attribute("LANGUAGE", in: $0) == "en" && $0.contains("DEFAULT=YES") }
                    ?? renditions.first { attribute("LANGUAGE", in: $0) == "en" } ?? renditions.first
                if let rendition {
                    if let reference = attribute("URI", in: rendition), let remote = BBCService.resolve(reference, base: url) {
                        let name = type.lowercased() + ".m3u8"
                        try await package.addPlaylist(remote, name: name, fetch: fetch)
                        master += rendition.replacingOccurrences(of: "URI=\"\(reference)\"", with: "URI=\"\(name)\"") + "\n"
                    } else { master += rendition + "\n" }
                }
            }
            try await package.addPlaylist(best.url, name: "video.m3u8", fetch: fetch)
            master += stream + "\nvideo.m3u8\n"
            package.playlists["master.m3u8"] = Data(master.utf8)
        } else {
            try await package.addPlaylist(url, name: "master.m3u8", fetch: fetch)
        }
        return package
    }
    private mutating func addPlaylist(_ url: URL, name: String, fetch: (URL) async throws -> Data) async throws {
        let text = String(decoding: try await fetch(url), as: UTF8.self)
        guard text.hasPrefix("#EXTM3U"), text.contains("#EXT-X-ENDLIST") else { throw BBCError.message("Only complete on-demand episodes can be downloaded. Live broadcasts cannot be saved.") }
        guard !text.contains("#EXT-X-KEY:"), !text.contains("#EXT-X-SESSION-KEY:"), !text.contains("#EXT-X-BYTERANGE:"), !text.contains("BYTERANGE=") else {
            throw BBCError.message("This stream uses protection or byte ranges that this downloader cannot save.")
        }
        var lines = [String]()
        for line in text.components(separatedBy: .newlines) {
            try Task.checkCancellation()
            if let reference = Self.attribute("URI", in: line) {
                guard let remote = BBCService.resolve(reference, base: url) else { throw BBCError.message("Invalid media address.") }
                let local = localName(remote)
                lines.append(line.replacingOccurrences(of: "URI=\"\(reference)\"", with: "URI=\"\(local)\""))
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard let remote = BBCService.resolve(line, base: url) else { throw BBCError.message("Invalid segment address.") }
                lines.append(localName(remote))
            } else { lines.append(line) }
        }
        playlists[name] = Data(lines.joined(separator: "\n").utf8)
    }
    private mutating func localName(_ url: URL) -> String {
        if let existing = media.first(where: { $0.value == url }) { return existing.key }
        let ext = ["mp4", "m4s", "ts", "aac", "vtt"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "bin"
        let name = "segment-\(media.count).\(ext)"; media[name] = url; return name
    }
    static func dash(_ manifest: DASHManifest) -> OfflinePackage {
        // The bridge uses subdirectories; flatten them so the offline server has an exact file allowlist.
        var playlists = [String: Data](), media = [String: URL]()
        for (path, data) in manifest.playlists {
            var text = String(decoding: data, as: UTF8.self)
            for key in manifest.mediaResources.keys.sorted(by: { $0.count > $1.count }) {
                text = text.replacingOccurrences(of: String(key.dropFirst()), with: key.dropFirst().replacingOccurrences(of: "/", with: "-"))
            }
            playlists[String(path.dropFirst())] = Data(text.utf8)
        }
        for (path, url) in manifest.mediaResources { media[path.dropFirst().replacingOccurrences(of: "/", with: "-")] = url }
        return OfflinePackage(playlists: playlists, media: media, height: manifest.video.height, videoRange: "HLG")
    }
}
