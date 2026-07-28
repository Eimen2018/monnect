import Foundation

struct DeviceConfig: Codable, Identifiable, Equatable {
    let name: String
    let address: String
    var id: String { address }
}

struct Config: Codable {
    var token: String
    var devices: [DeviceConfig]

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Monnect/config.json")
    }

    static func load() -> Config? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }
}
