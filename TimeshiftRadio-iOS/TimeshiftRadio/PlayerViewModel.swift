import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

@MainActor
class PlayerViewModel: ObservableObject {

    // MARK: - Published state
    @Published var nowPlaying: NowPlayingResponse?
    @Published var isLoading = false
    @Published var isAudioLoading = false
    @Published var isPlaying = false
    @Published var errorMessage: String?

    @Published var selectedChannel: Channel = Channel.all[0]
    @Published var userTimezone: String = TimeZone.current.identifier

    // MARK: - Private
    private var player: AVPlayer?
    private var refreshTask: Task<Void, Never>?
    private var currentShowID: String?

    // MARK: - Computed helpers
    var currentShow: Show? { nowPlaying?.show }
    var targetCphTime: String { nowPlaying?.targetCphTime ?? "" }
    var scheduleDate: String { nowPlaying?.scheduleDate ?? "" }
    var localTime: String { nowPlaying?.user?.localTime ?? "" }

    // MARK: - Lifecycle

    init() {
        setupAudioSession()
        setupRemoteCommands()
    }

    func start() {
        Task { await refresh() }
        scheduleAutoRefresh()
    }

    // MARK: - Data loading

    func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await RadioAPI.fetchNowPlaying(
                channel: selectedChannel.slug,
                timezone: userTimezone
            )
            nowPlaying = response

            // Load audio only if show changed
            if let show = response.show,
               show.isAvailableOnDemand == true,
               show.id != currentShowID {
                currentShowID = show.id
                await loadAudio(for: show)
            } else if response.show?.isAvailableOnDemand != true {
                stopAudio()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func switchChannel(to channel: Channel) {
        selectedChannel = channel
        currentShowID = nil
        stopAudio()
        Task { await refresh() }
    }

    // MARK: - Audio

    private func loadAudio(for show: Show) async {
        guard let presentationURL = show.presentationUrl else { return }
        isAudioLoading = true
        do {
            let stream = try await RadioAPI.fetchStreamURL(presentationURL: presentationURL)
            guard let url = URL(string: stream.url) else { return }
            play(url: url, show: show)
        } catch {
            // Audio unavailable — silent fail
        }
        isAudioLoading = false
    }

    private func play(url: URL, show: Show) {
        player?.pause()
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.play()
        isPlaying = true
        updateNowPlayingInfo(show: show)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    }

    private func stopAudio() {
        player?.pause()
        player = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Now Playing Info (lock screen)

    private func updateNowPlayingInfo(show: Show) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: show.title ?? "DR Radio",
            MPMediaItemPropertyArtist: selectedChannel.name,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Load artwork async
        if let artURL = show.squareImageURL {
            Task {
                if let data = try? Data(contentsOf: artURL),
                   let uiImage = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
    }

    // MARK: - Setup

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            self?.isPlaying = true
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            self?.isPlaying = false
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            self?.stopAudio()
            return .success
        }
    }

    private func scheduleAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3 * 60 * 1_000_000_000)
                if !Task.isCancelled {
                    await refresh()
                }
            }
        }
    }
}
