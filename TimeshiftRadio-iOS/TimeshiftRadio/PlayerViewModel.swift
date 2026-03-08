import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

@MainActor
class PlayerViewModel: ObservableObject {

    @Published var nowPlaying: NowPlayingResponse?
    @Published var isLoading = false
    @Published var isAudioLoading = false
    @Published var isPlaying = false
    @Published var errorMessage: String?
    @Published var selectedChannel: Channel = Channel.all[0]
    @Published var userTimezone: String = TimeZone.current.identifier

    private var player: AVPlayer?
    private var playerEndObserver: Any?
    private var refreshTask: Task<Void, Never>?
    private var currentShowID: String?
    private var queuedNextShow: Show?

    var currentShow: Show? { nowPlaying?.show }
    var targetCphTime: String { nowPlaying?.targetCphTime ?? "" }
    var scheduleDate: String { nowPlaying?.scheduleDate ?? "" }
    var localTime: String { nowPlaying?.user?.localTime ?? "" }

    init() { setupAudioSession(); setupRemoteCommands() }

    func start() { Task { await refresh() }; scheduleAutoRefresh() }

    func refresh() async {
        isLoading = true; errorMessage = nil
        do {
            let response = try await RadioAPI.fetchNowPlaying(channel: selectedChannel.slug, timezone: userTimezone)
            nowPlaying = response
            queuedNextShow = response.nextShow
            if let show = response.show, show.isAvailableOnDemand == true, show.id != currentShowID {
                currentShowID = show.id
                await loadAudio(for: show)
            } else if response.show?.isAvailableOnDemand != true {
                stopAudio()
            }
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    func switchChannel(to channel: Channel) {
        selectedChannel = channel; currentShowID = nil; queuedNextShow = nil
        stopAudio(); Task { await refresh() }
    }

    private func loadAudio(for show: Show) async {
        guard let presentationURL = show.presentationUrl else { return }
        isAudioLoading = true
        do {
            let stream = try await RadioAPI.fetchStreamURL(presentationURL: presentationURL)
            guard let url = URL(string: stream.url) else { isAudioLoading = false; return }
            play(url: url, show: show)
        } catch {}
        isAudioLoading = false
    }

    private func play(url: URL, show: Show) {
        if let obs = playerEndObserver { NotificationCenter.default.removeObserver(obs) }
        player?.pause()
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.play()
        isPlaying = true
        updateNowPlayingInfo(show: show)
        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in await self?.playNextShow() } }
    }

    private func playNextShow() async {
        guard let next = queuedNextShow else { await refresh(); return }
        guard next.isAvailableOnDemand == true else { currentShowID = nil; await refresh(); return }
        nowPlaying = NowPlayingResponse(status: nowPlaying?.status ?? "ok", channel: nowPlaying?.channel,
            targetCphTime: nowPlaying?.targetCphTime, scheduleDate: nowPlaying?.scheduleDate,
            show: next, nextShow: nil, user: nowPlaying?.user)
        currentShowID = next.id; queuedNextShow = nil
        await loadAudio(for: next)
        Task {
            if let ch = nowPlaying?.channel,
               let updated = try? await RadioAPI.fetchNowPlaying(channel: ch, timezone: userTimezone) {
                queuedNextShow = updated.nextShow
            }
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    }

    private func stopAudio() {
        if let obs = playerEndObserver { NotificationCenter.default.removeObserver(obs); playerEndObserver = nil }
        player?.pause(); player = nil; isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlayingInfo(show: Show) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: show.title ?? "DR Radio",
            MPMediaItemPropertyArtist: selectedChannel.name,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if let artURL = show.squareImageURL {
            Task {
                if let data = try? Data(contentsOf: artURL), let uiImage = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
    }

    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.player?.play(); self?.isPlaying = true; return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.player?.pause(); self?.isPlaying = false; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in await self?.playNextShow() }; return .success }
        c.stopCommand.addTarget { [weak self] _ in self?.stopAudio(); return .success }
    }

    private func scheduleAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3 * 60 * 1_000_000_000)
                if !Task.isCancelled { await refresh() }
            }
        }
    }
}
