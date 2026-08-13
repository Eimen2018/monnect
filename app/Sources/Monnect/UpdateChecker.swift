import Foundation

struct LatestRelease: Equatable {
    let version: String
    let url: URL
}

/// Compares the running bundle version against the newest GitHub release.
/// The only network call the app makes beyond the local network; disable
/// with `checkForUpdates: false` in config.json.
enum UpdateChecker {
    static let releasesAPI = URL(string: "https://api.github.com/repos/Eimen2018/monnect/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func fetchLatest(completion: @escaping (LatestRelease?) -> Void) {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let urlString = obj["html_url"] as? String,
                  let url = URL(string: urlString) else {
                completion(nil)
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            completion(LatestRelease(version: version, url: url))
        }.resume()
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
