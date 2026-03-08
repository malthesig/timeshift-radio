import SwiftUI

struct ContentView: View {
    @StateObject private var vm = PlayerViewModel()

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                headerView
                channelPicker
                Spacer()
                mainCard
                Spacer()
                playerControls
                contextNote
            }
            .padding(.horizontal)
        }
        .onAppear { vm.start() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 4) {
            Text("DR LYD")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(red: 0.89, green: 0, blue: 0.1))
                .cornerRadius(4)
            Text("Timeshift Radio")
                .font(.title2)
                .fontWeight(.bold)
            Text("The same show, at your local hour")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Channel Picker

    private var channelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Channel.all) { channel in
                    Button(action: { vm.switchChannel(to: channel) }) {
                        Text(channel.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                vm.selectedChannel.slug == channel.slug
                                    ? Color(red: 0.89, green: 0, blue: 0.1)
                                    : Color(.secondarySystemBackground)
                            )
                            .foregroundColor(.white)
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.bottom, 16)
    }

    // MARK: - Main Card

    private var mainCard: some View {
        VStack(spacing: 0) {
            // Now Playing header
            HStack {
                Circle()
                    .fill(Color(red: 0.89, green: 0, blue: 0.1))
                    .frame(width: 8, height: 8)
                    .opacity(vm.isLoading ? 0.4 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(), value: vm.isLoading)
                Text("NOW PLAYING")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .kerning(0.5)
                Spacer()
                LiveClock(timezone: vm.userTimezone)
            }
            .padding()
            .background(Color(.tertiarySystemBackground))

            Divider()

            if vm.isLoading && vm.currentShow == nil {
                loadingView
            } else if let error = vm.errorMessage {
                errorView(error)
            } else if let show = vm.currentShow {
                showInfoView(show)
            } else {
                noShowView
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.separator), lineWidth: 0.5))
    }

    // MARK: - Show Info

    private func showInfoView(_ show: Show) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                AsyncImage(url: show.squareImageURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color(.tertiarySystemBackground)
                            .overlay(Image(systemName: "radio").foregroundColor(.secondary))
                    }
                }
                .frame(width: 90, height: 90)
                .cornerRadius(10)

                VStack(alignment: .leading, spacing: 6) {
                    Text(show.title ?? "Unknown programme")
                        .font(.headline)
                        .lineLimit(2)

                    if let desc = show.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }

                    Text(show.formattedTimeRange)
                        .font(.caption2)
                        .foregroundColor(Color(.tertiaryLabel))

                    if show.isAvailableOnDemand != true {
                        Text("Not available on demand")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(.tertiarySystemBackground))
                            .cornerRadius(4)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Player Controls

    private var playerControls: some View {
        Group {
            if let show = vm.currentShow, show.isAvailableOnDemand == true {
                HStack(spacing: 28) {
                    Spacer()
                    Button(action: { vm.togglePlayPause() }) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.89, green: 0, blue: 0.1))
                                .frame(width: 64, height: 64)
                            if vm.isAudioLoading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: - Context Note

    private var contextNote: some View {
        Group {
            if let cphTime = nowPlaying?.targetCphTime, let date = nowPlaying?.scheduleDate {
                Text("Your \(vm.localTime) → playing DR \(vm.selectedChannel.name) at \(cphTime) Copenhagen time on \(date)")
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        HStack {
            Spacer()
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…").font(.caption).foregroundColor(.secondary)
            }
            .padding(32)
            Spacer()
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundColor(.orange)
            Text(msg).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await vm.refresh() } }
                .font(.caption).foregroundColor(Color(red: 0.89, green: 0, blue: 0.1))
        }
        .padding(32)
    }

    private var noShowView: some View {
        VStack(spacing: 8) {
            Image(systemName: "radio").font(.title2).foregroundColor(.secondary)
            Text("No programme scheduled now").font(.caption).foregroundColor(.secondary)
        }
        .padding(32)
    }

    private var nowPlaying: NowPlayingResponse? { vm.nowPlaying }
}

// MARK: - Live Clock

struct LiveClock: View {
    let timezone: String
    @State private var time = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(time)
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(.secondary)
            .onReceive(timer) { _ in updateTime() }
            .onAppear { updateTime() }
    }

    private func updateTime() {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: timezone)
        time = fmt.string(from: Date())
    }
}

#Preview {
    ContentView()
}
