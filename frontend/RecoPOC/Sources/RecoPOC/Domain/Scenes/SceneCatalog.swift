import Foundation

public struct RecoScene: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public enum SceneCatalog {
    public static let all: [RecoScene] = [
        RecoScene(id: 0, name: "放松"),
        RecoScene(id: 1, name: "图书馆"),
        RecoScene(id: 2, name: "健身"),
        RecoScene(id: 3, name: "通勤"),
        RecoScene(id: 4, name: "游戏"),
        RecoScene(id: 5, name: "专注"),
        RecoScene(id: 6, name: "阅读"),
        RecoScene(id: 7, name: "深睡眠"),
        RecoScene(id: 8, name: "减压"),
        RecoScene(id: 9, name: "婴儿安睡"),
        RecoScene(id: 10, name: "胎教"),
        RecoScene(id: 11, name: "宠物陪伴"),
        RecoScene(id: 12, name: "经期舒缓"),
        RecoScene(id: 13, name: "睡午觉"),
        RecoScene(id: 14, name: "跑步"),
        RecoScene(id: 15, name: "瑜伽"),
        RecoScene(id: 16, name: "冥想"),
        RecoScene(id: 17, name: "深夜EMO")
    ]

    public static let names: [String] = all.map(\.name)

    public static func scene(named name: String) -> RecoScene? {
        all.first { $0.name == name }
    }
}
