import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case noShow
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .noShow: return "No programme scheduled at this time"
        case .httpError(let code): return "Server error (\(code))"
        }
    }
}

class RadioAPI {
    // ⚠️ Update this URL after deploying to Render
    static var baseURL = "https://timeshift-radio.onrender.com"

    static func fetchNowPlaying(channel: String, timezone: String) async throws -> NowPlayingResponse {
        var comps = URLComponents(string: "\(baseURL)/api/now")!
        comps.queryItems = [
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "user_tz", value: timezone),
        ]
        guard let url = comps.url else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(NowPlayingResponse.self, from: data)
    }

    static func fetchStreamURL(presentationURL: String) async throws -> StreamResponse {
        var comps = URLComponents(string: "\(baseURL)/api/stream")!
        comps.queryItems = [
            URLQueryItem(name: "presentation_url", value: presentationURL),
        ]
        guard let url = comps.url else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(StreamResponse.self, from: data)
    }
}
