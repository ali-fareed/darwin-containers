import Foundation
import Virtualization

private struct IpswListModel: Codable {
    struct IpswModel: Codable {
        var name: String
        var build: String
        var url: String
    }
    
    var restoreImages: [IpswModel]
}

enum InstallationImages {
    private static func list() -> [IpswListModel.IpswModel] {
        guard let url = Bundle.main.url(forResource: "ipsw-list", withExtension: "json"), let data = try? Data(contentsOf: url) else {
            print("Could not load ipsw list")
            return []
        }
        guard let list = try? JSONDecoder().decode(IpswListModel.self, from: data) else {
            print("Could not load ipsw list")
            return []
        }
        return list.restoreImages
    }
    
    static func listAvailable() -> [String] {
        return list().map(\.name)
    }
    
    static func url(for name: String) -> URL? {
        guard let item = list().first(where: { $0.name == name }) else {
            return nil
        }
        return URL(string: item.url)
    }
    
    private static func imagePath(basePath: String, name: String) -> String {
        let escapedName = name.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<'>")).joined(separator: "")
        return basePath + "/" + escapedName + ".ipsw"
    }
    
    static func fetchedPath(basePath: String, name: String) -> String? {
        let path = imagePath(basePath: basePath, name: name)
        if FileManager.default.fileExists(atPath: path) {
            return path
        } else {
            return nil
        }
    }
    
    static func storeFetched(location: URL, basePath: String, name: String) {
        let _ = try? FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: imagePath(basePath: basePath, name: name)))
    }
}
