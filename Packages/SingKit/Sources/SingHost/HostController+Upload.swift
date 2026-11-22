#if os(macOS)
import CryptoKit
import Foundation
import GRDB
import SingCore

/// A song's lyrics waiting to be shared with the Sing lyrics database.
struct PendingUpload: Codable, Sendable, Hashable {
    var songID: SongID
    var attempts = 0
    var nextTry = Date.distantPast
}

/// Signs and sends AI-synced or hand-fixed lyrics to the upload API; a queue keeps them while offline.
extension HostController {
    var deviceKeyURL: URL { paths.root.appendingPathComponent("device-key") }

    /// This Mac's Ed25519 key, created once and kept readable only by this user.
    func deviceKey() -> Curve25519.Signing.PrivateKey {
        if let d = try? Data(contentsOf: deviceKeyURL), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.Signing.PrivateKey()
        try? k.rawRepresentation.write(to: deviceKeyURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deviceKeyURL.path)
        return k
    }

    var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "uploadDeviceID") { return id }
        let id = "mac-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "uploadDeviceID")
        return id
    }

    func loadUploads() async {
        let stored = try? await database.writer.read { try SettingRecord.fetchOne($0, key: "uploadQueue") }
        uploads = stored.flatMap { try? JSONDecoder().decode([PendingUpload].self, from: Data($0.json.utf8)) } ?? []
    }

    func saveUploads() {
        let json = String(decoding: (try? JSONEncoder().encode(uploads)) ?? Data("[]".utf8), as: UTF8.self)
        Task { try? await database.writer.write { db in try SettingRecord(key: "uploadQueue", json: json).save(db) } }
    }

    /// Queues lyrics worth sharing: word timing from the AI that needs no review, or fixed by hand.
    func considerUpload(_ id: SongID) async {
        guard settings.services.uploadsEnabled, let r = try? await library.song(id), let l = lyricsService.cached(r),
              l.kind >= .word, l.source == .ai || l.source == .manual, l.needsReview != true,
              !FileManager.default.fileExists(atPath: paths.songCache(r.audioHash).appendingPathComponent("uploaded").path),
              !uploads.contains(where: { $0.songID == id }) else { return }
        uploads.append(PendingUpload(songID: id))
        saveUploads()
    }

    public var pendingUploads: Int { uploads.count }

    /// A person checked the AI timing: clear the review flag so it can be shared.
    public func markLyricsReviewed(_ id: SongID) async {
        guard let r = try? await library.song(id), var l = lyricsService.cached(r) else { return }
        l.needsReview = false
        try? JSONEncoder().encode(l).write(to: paths.lyrics(r.audioHash))
        await considerUpload(id)
    }

    /// Sends what is due; failures wait longer each time, and nothing blocks the party.
    func processUploads() async {
        guard settings.services.uploadsEnabled, !uploads.isEmpty, let base = URL(string: settings.services.uploadAPIBase) else { return }
        await registerDeviceIfNeeded(base)
        for item in uploads where item.nextTry <= .now {
            let ok = await upload(item.songID, base: base)
            if let i = uploads.firstIndex(of: item) {
                if ok { uploads.remove(at: i) } else {
                    uploads[i].attempts += 1
                    uploads[i].nextTry = .now.addingTimeInterval(min(86400, 300 * pow(2, Double(uploads[i].attempts))))
                }
            }
        }
        saveUploads()
    }

    func signedRequest(_ url: URL, method: String, body: Data) -> URLRequest {
        let ts = String(Int64(Date.now.timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = "\(method)\n\(url.path)\n\(ts)\n\(nonce)\n\(hash)"
        let sig = (try? deviceKey().signature(for: Data(canonical.utf8))) ?? Data()
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = 20
        r.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        r.setValue(ts, forHTTPHeaderField: "X-Timestamp")
        r.setValue(nonce, forHTTPHeaderField: "X-Nonce")
        r.setValue(sig.base64EncodedString(), forHTTPHeaderField: "X-Signature")
        return r
    }

    /// Self-registration: the API learns this Mac's public key once (rate limited and revocable on the server).
    func registerDeviceIfNeeded(_ base: URL) async {
        guard !UserDefaults.standard.bool(forKey: "uploadDeviceRegistered") else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["deviceId": deviceID, "publicKey": deviceKey().publicKey.rawRepresentation.base64EncodedString(), "name": serverName])
        var r = URLRequest(url: base.appendingPathComponent("v1/devices/register"))
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let (_, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode, code == 200 || code == 201 || code == 409 {
            UserDefaults.standard.set(true, forKey: "uploadDeviceRegistered")
        }
    }

    func upload(_ id: SongID, base: URL) async -> Bool {
        guard let r = try? await library.song(id), let l = lyricsService.cached(r) else { return true }
        let ttml = TTMLWriter.write(l, title: r.title, artist: r.artist)
        var url: URL
        if let isrc = r.isrc, !isrc.isEmpty {
            url = base.appendingPathComponent("v1/lyrics/\(isrc)")
        } else {
            var c = URLComponents(url: base.appendingPathComponent("v1/lyrics"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "title", value: r.title), URLQueryItem(name: "artist", value: r.artist), URLQueryItem(name: "durationMs", value: String(r.durationMs))]
            url = c.url!
        }
        var req = signedRequest(url, method: "POST", body: ttml)
        req.setValue("application/ttml+xml", forHTTPHeaderField: "Content-Type")
        if let lang = l.language { req.setValue(lang, forHTTPHeaderField: "X-Language") }
        req.setValue(l.kind >= .word ? "true" : "false", forHTTPHeaderField: "X-Word-Synced")
        req.setValue(l.source == .manual ? "human" : "ai", forHTTPHeaderField: "X-Source")
        if let m = l.model { req.setValue(m, forHTTPHeaderField: "X-Model") }
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        if (200..<300).contains(code) {
            try? Data().write(to: paths.songCache(r.audioHash).appendingPathComponent("uploaded"))
            return true
        }
        if code == 401 { UserDefaults.standard.set(false, forKey: "uploadDeviceRegistered") }
        return code == 400 || code == 404 || code == 409
    }
}
#endif
