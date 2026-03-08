import Foundation

// MARK: - Channel

struct Channel: Identifiable, Hashable {
    let id = UUID()
    let slug: String
    let name: String
    let description: String

    static let all: [Channel] = [
        Channel(slug: "p1",      name: "P1",         description: "Nyheder & kultur"),
        Channel(slug: "p2",      name: "P2 Klassisk", description: "Klassisk musik"),
        Channel(slug: "p3",      name: "P3",          description: "Pop & rock"),
        Channel(slug: "p4",      name: "P4",          description: "Regional radio"),
        Channel(slug: "p5",      name: "P5",          description: "Klassiske hits"),
        Channel(slug: "p6-beat", name: "P6 Beat",     description: "Alternativ musik"),
        Channel(slug: "p7-mix",  name: "P7 Mix",      description: "Nostalgisk musik"),
        Channel(slug: "p8-jazz", name: "P8 Jazz",     description: "Jazz"),
    ]
}

// MARK: - API Response Models

struct NowPlayingResponse: Codable {
    let status: String
    let channel: String?
    let targetCphTime: String?
    let scheduleDate: String?
    let show: Show?
    let user: UserInfo?

    enum CodingKeys: String, CodingKey {
        case status, channel, show, user
        case targetCphTime = "target_cph_time"
        case scheduleDate = "schedule_date"
    }
}

struct Show: Codable, Identifiable {
    let id: String?
    let title: String?
    let description: String?
    let startTime: String?
    let endTime: String?
    let isAvailableOnDemand: Bool?
    let presentationUrl: String?
    let imageAssets: [ImageAsset]?

    var squareImageURL: URL? {
        let asset = imageAssets?.first(where: { $0.target == "SquareImage" }) ?? imageAssets?.first
        guard let urn = asset?.id else { return nil }
        let encoded = "AspectCrop=(300,300),xPosition=.5,yPosition=.5;Resize=(300,300)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://asset.dr.dk/drlyd/images/\(urn)?im=\(encoded)")
    }

    var formattedTimeRange: String {
        guard let start = startTime, let end = endTime else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        fmt.timeZone = TimeZone(identifier: "Europe/Copenhagen")
        let out = DateFormatter()
        out.dateFormat = "HH:mm"
        out.timeZone = TimeZone(identifier: "Europe/Copenhagen")
        let s = fmt.date(from: start).map { out.string(from: $0) } ?? ""
        let e = fmt.date(from: end).map { out.string(from: $0) } ?? ""
        return "\(s) – \(e) Copenhagen"
    }
}

struct ImageAsset: Codable {
    let id: String
    let ratio: String?
    let target: String?
    let format: String?
}

struct UserInfo: Codable {
    let timezone: String
    let localTime: String
    let localDate: String
}

struct StreamResponse: Codable {
    let url: String
    let format: String?
    let bitrate: Int?
}
