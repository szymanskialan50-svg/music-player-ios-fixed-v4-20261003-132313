// Music Player — Copyright (c) 2026 x3lanix. All rights reserved.
// Based on youtube-ios-player-helper (Google Inc., Apache License 2.0); modified. See NOTICE.md.

import Foundation
import Capacitor
import WebKit
import AVFoundation
import MediaPlayer
import UIKit

@objc(YouTubeCapacitorPlugin)
public class YouTubeCapacitorPlugin: CAPPlugin {

    private var player: YouTubePlayer?
    private var timer: Timer?
    private var intendedPlaybackState = "paused"
    private let silentPlayer = SilentAudioPlayer()
    private var didNotifyErrorForCurrentLoad = false
    /// Only tell JS about *changes* of the player state (it used to get the same
    /// state 10x per second, each time re-rendering the whole track list = lag).
    private var lastNotifiedState = ""
    private var cachedDuration: Double = 0
    private var lastDurationFetch = Date.distantPast

    /// true while the system (phone call, Siri, another app) owns the audio session.
    /// During that time we must NOT fight the system by force-resuming.
    private var isInterrupted = false
    private var lastResumeAttempt = Date.distantPast
    private var lastNowPlayingUpdate = Date.distantPast

    // Now Playing (lock screen / Control Center) state
    private var npTitle = ""
    private var npArtist = ""
    private var npArtwork: MPMediaItemArtwork?
    private var npDuration: Double = 0
    private var npElapsed: Double = 0
    private var remoteCommandsConfigured = false

    // Native auto-advance: JS hands us the upcoming YouTube tracks so the next
    // song starts even when iOS has suspended the main web view in background.
    private struct UpNextItem {
        let videoId: String; let index: Int
        let title: String; let artist: String
        let duration: Double; let artworkUrl: String?
    }
    private var upNext: [UpNextItem] = []
    private var repeatOne = false
    private var didHandleEndForCurrentLoad = false
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Lifecycle

    public override func load() {
        super.load()
        DispatchQueue.main.async {
            self.activateAudioSession()
            self.silentPlayer.play() // keeps the process "audible" so iOS doesn't suspend it

            // Page-Visibility spoof for the main Capacitor WebView.
            if let webView = self.bridge?.webView {
                let source = """
                Object.defineProperty(document, 'visibilityState', { get: function() { return 'visible'; } });
                Object.defineProperty(document, 'hidden', { get: function() { return false; } });
                document.addEventListener('visibilitychange', function(e) { e.stopImmediatePropagation(); }, true);
                """
                let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                webView.configuration.userContentController.addUserScript(script)
            }

            self.player = YouTubePlayer()
            self.setupRemoteCommands()

            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(self.appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.mediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.engineConfigChanged), name: .AVAudioEngineConfigurationChange, object: nil)
            nc.addObserver(self, selector: #selector(self.routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        }
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    /// The YouTube web view must stay a real, non-hidden view inside the window.
    /// A `isHidden = true` WKWebView gets its media suspended by iOS the moment
    /// the app is backgrounded - that was the main cause of the music stopping.
    /// It sits *behind* the main web view, so the user never sees it.
    private func attachPlayerWebViewIfNeeded() {
        guard let wv = player?.webView, wv.superview == nil else { return }
        wv.isHidden = false
        wv.alpha = 0.01
        wv.isUserInteractionEnabled = false
        wv.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        if let main = bridge?.webView, let parent = main.superview {
            parent.insertSubview(wv, belowSubview: main)
        } else if let root = bridge?.viewController?.view {
            root.addSubview(wv)
        }
    }

    // MARK: - Background / interruption handling

    /// Resume playback right away and a few more times shortly after.
    /// WebKit pauses media for a split second when the app changes state
    /// (that was the 0.5s "stutter"); re-issuing play immediately - and again
    /// after short delays - makes the transition seamless, like Spotify.
    private func resumeIfIntended() {
        guard intendedPlaybackState == "playing", !isInterrupted else { return }
        activateAudioSession()
        silentPlayer.play()
        player?.play()
        for delay in [0.1, 0.3, 0.6, 1.0, 1.6, 2.5, 4.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.intendedPlaybackState == "playing", !self.isInterrupted else { return }
                let st = self.player?.playerState
                if st != .playing && st != .buffering {
                    self.activateAudioSession()
                    self.silentPlayer.play()
                    self.player?.play()
                }
            }
        }
    }

    /// Extra grace period from iOS while we re-establish playback.
    private func beginResumeTask() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "music-resume") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid
        }
    }

    @objc func appWillResignActive() {
        DispatchQueue.main.async {
            self.beginResumeTask()
            self.resumeIfIntended()
        }
    }
    @objc func appDidEnterBackground() {
        DispatchQueue.main.async {
            self.beginResumeTask()
            self.resumeIfIntended()
        }
    }
    @objc func appDidBecomeActive() {
        DispatchQueue.main.async {
            if self.bgTask != .invalid { UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid }
            self.resumeIfIntended()
        }
    }
    @objc func engineConfigChanged() {
        DispatchQueue.main.async { if self.intendedPlaybackState == "playing" { self.silentPlayer.restart() } }
    }
    @objc func mediaServicesReset() { DispatchQueue.main.async { self.resumeIfIntended() } }

    @objc func routeChanged(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones unplugged -> iOS convention is to pause (like Spotify).
        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async {
                self.intendedPlaybackState = "paused"
                self.player?.pause()
                self.silentPlayer.pause()
            }
        }
    }

    @objc func audioInterrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.isInterrupted = true
            } else {
                self.isInterrupted = false
                let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                    self.resumeIfIntended()
                } else {
                    self.intendedPlaybackState = "paused"
                }
            }
        }
    }

    // MARK: - Lock screen / Control Center (Now Playing)

    private func setupRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in self?.remotePlay(); return .success }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in self?.remotePause(); return .success }
        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.intendedPlaybackState == "playing" { self.remotePause() } else { self.remotePlay() }
            return .success
        }
        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.notifyListeners("youtubeRemoteCommand", data: ["command": "next"]); return .success
        }
        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.notifyListeners("youtubeRemoteCommand", data: ["command": "previous"]); return .success
        }
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player?.seekTo(Float(e.positionTime), allowSeekAhead: true)
            self?.npElapsed = e.positionTime
            self?.pushNowPlaying()
            return .success
        }
        cc.skipForwardCommand.isEnabled = false
        cc.skipBackwardCommand.isEnabled = false
    }

    private func remotePlay() {
        DispatchQueue.main.async {
            self.isInterrupted = false
            self.intendedPlaybackState = "playing"
            self.activateAudioSession()
            self.silentPlayer.play()
            self.player?.play()
            self.pushNowPlaying()
        }
    }

    private func remotePause() {
        DispatchQueue.main.async {
            self.intendedPlaybackState = "paused"
            self.player?.pause()
            self.silentPlayer.pause()
            self.pushNowPlaying()
        }
    }

    private func pushNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: npTitle,
            MPMediaItemPropertyArtist: npArtist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: npElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: intendedPlaybackState == "playing" ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if npDuration > 0 { info[MPMediaItemPropertyPlaybackDuration] = npDuration }
        if let art = npArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = intendedPlaybackState == "playing" ? .playing : .paused
    }

    @objc func setNowPlaying(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? ""
        let artist = call.getString("artist") ?? ""
        let duration = call.getDouble("duration") ?? 0
        let artworkUrl = call.getString("artworkUrl")
        DispatchQueue.main.async {
            self.npTitle = title
            self.npArtist = artist
            self.npDuration = duration
            self.npElapsed = 0
            self.npArtwork = nil
            self.pushNowPlaying()
            call.resolve()
        }
        if let s = artworkUrl, let url = URL(string: s) {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self, let data = data, let img = UIImage(data: data) else { return }
                let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                DispatchQueue.main.async {
                    // only apply if the track hasn't changed in the meantime
                    if self.npTitle == title { self.npArtwork = art; self.pushNowPlaying() }
                }
            }.resume()
        }
    }

    // MARK: - Plugin methods

    @objc func load(_ call: CAPPluginCall) {
        let videoId = call.getString("videoId") ?? ""
        DispatchQueue.main.async {
            self.didNotifyErrorForCurrentLoad = false
            self.didHandleEndForCurrentLoad = false
            self.lastNotifiedState = ""
            self.cachedDuration = 0
            self.isInterrupted = false
            self.intendedPlaybackState = "playing"
            self.activateAudioSession()
            self.silentPlayer.play()
            self.player?.load(videoId: videoId)
            self.attachPlayerWebViewIfNeeded()
            self.startStateObserver()
            call.resolve()
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.isInterrupted = false
            self.intendedPlaybackState = "playing"
            self.activateAudioSession()
            self.player?.play()
            self.silentPlayer.play()
            self.pushNowPlaying()
            call.resolve()
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.intendedPlaybackState = "paused"
            self.player?.pause()
            self.silentPlayer.pause()
            self.pushNowPlaying()
            call.resolve()
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.intendedPlaybackState = "paused"
            self.player?.stop()
            self.silentPlayer.pause()
            self.stopStateObserver()
            call.resolve()
        }
    }

    @objc func seekTo(_ call: CAPPluginCall) {
        let seconds = call.getFloat("seconds") ?? 0
        DispatchQueue.main.async {
            self.player?.seekTo(seconds, allowSeekAhead: true)
            call.resolve()
        }
    }

    @objc func setVolume(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func setUpNext(_ call: CAPPluginCall) {
        let raw = call.getArray("items", JSObject.self) ?? []
        let rep = call.getBool("repeatOne") ?? false
        DispatchQueue.main.async {
            self.repeatOne = rep
            self.upNext = raw.compactMap { o in
                guard let vid = o["videoId"] as? String, !vid.isEmpty,
                      let idx = o["index"] as? Int else { return nil }
                return UpNextItem(videoId: vid, index: idx,
                                  title: o["title"] as? String ?? "",
                                  artist: o["artist"] as? String ?? "",
                                  duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0,
                                  artworkUrl: o["artworkUrl"] as? String)
            }
            call.resolve()
        }
    }

    @objc func setTheme(_ call: CAPPluginCall) {
        let theme = call.getString("theme") ?? "system"
        DispatchQueue.main.async {
            let style: UIUserInterfaceStyle = theme == "light" ? .light : (theme == "dark" ? .dark : .unspecified)
            self.bridge?.viewController?.overrideUserInterfaceStyle = style
            call.resolve()
        }
    }

    /// Called when the current track ended. Returns true if we handled it natively.
    private func handleTrackEnded() -> Bool {
        if didHandleEndForCurrentLoad { return true }
        if repeatOne {
            didHandleEndForCurrentLoad = true
            intendedPlaybackState = "playing"
            player?.seekTo(0, allowSeekAhead: true)
            player?.play()
            // allow the next end to be handled again once playback restarts
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.didHandleEndForCurrentLoad = false }
            return true
        }
        guard !upNext.isEmpty else { return false }
        didHandleEndForCurrentLoad = true
        let item = upNext.removeFirst()
        didNotifyErrorForCurrentLoad = false
        lastNotifiedState = ""
        cachedDuration = 0
        intendedPlaybackState = "playing"
        activateAudioSession()
        silentPlayer.play()
        player?.load(videoId: item.videoId)
        player?.play()
        // reset flag once the new video is actually on its way
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.didHandleEndForCurrentLoad = false }
        npTitle = item.title; npArtist = item.artist; npDuration = item.duration; npElapsed = 0; npArtwork = nil
        pushNowPlaying()
        if let s = item.artworkUrl, let url = URL(string: s) {
            let title = item.title
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self, let data = data, let img = UIImage(data: data) else { return }
                let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                DispatchQueue.main.async { if self.npTitle == title { self.npArtwork = art; self.pushNowPlaying() } }
            }.resume()
        }
        notifyListeners("youtubeAdvanced", data: ["index": item.index, "videoId": item.videoId])
        return true
    }

    // MARK: - State observer

    private func startStateObserver() {
        stopStateObserver()
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.notifyState()
            }
            if let t = self.timer { RunLoop.main.add(t, forMode: .common) }
        }
    }

    private func stopStateObserver() {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    private func notifyState() {
        guard let player = self.player else { return }

        let stateStr: String
        switch player.playerState {
        case .unstarted: stateStr = "unstarted"
        case .ended: stateStr = "ended"
        case .playing: stateStr = "playing"
        case .paused: stateStr = "paused"
        case .buffering: stateStr = "buffering"
        case .cued: stateStr = "cued"
        case .unknown: stateStr = "unknown"
        }

        if stateStr == "playing" && intendedPlaybackState == "paused" {
            player.pause()
            silentPlayer.pause()
            return
        }

        // The user wants music, but WebKit/iOS paused the page behind our back
        // (backgrounding, screen lock, app switch) -> silently resume it and do
        // NOT tell JS it was paused, so the UI doesn't flicker.
        if stateStr == "paused" && intendedPlaybackState == "playing" && !isInterrupted {
            if Date().timeIntervalSince(lastResumeAttempt) > 0.4 {
                lastResumeAttempt = Date()
                activateAudioSession()
                silentPlayer.play()
                player.play()
            }
            return
        }

        if stateStr == "ended" && handleTrackEnded() { return }

        if stateStr != lastNotifiedState {
            lastNotifiedState = stateStr
            notifyListeners("youtubeStateChange", data: ["state": stateStr])
        }

        if let error = player.lastError, !didNotifyErrorForCurrentLoad {
            didNotifyErrorForCurrentLoad = true
            notifyListeners("youtubeError", data: ["error": String(describing: error)])
        }

        // Duration practically never changes while a track plays: ask for it
        // rarely instead of on every tick (halves the JS round-trips).
        let needDuration = cachedDuration <= 0 || Date().timeIntervalSince(lastDurationFetch) > 3
        let knownDuration = cachedDuration
        Task {
            do {
                let duration: Double
                if needDuration {
                    let fetched = try await player.duration()
                    duration = fetched
                    DispatchQueue.main.async { self.cachedDuration = fetched; self.lastDurationFetch = Date() }
                } else {
                    duration = knownDuration
                }
                let currentTime = try await player.currentTime()
                self.notifyListeners("youtubeTimeUpdate", data: [
                    "currentTime": currentTime,
                    "duration": duration
                ])
                // refresh lock-screen progress about once per second
                if Date().timeIntervalSince(self.lastNowPlayingUpdate) > 1.0 {
                    self.lastNowPlayingUpdate = Date()
                    DispatchQueue.main.async {
                        self.npElapsed = Double(currentTime)
                        if duration > 0 { self.npDuration = duration }
                        self.pushNowPlaying()
                    }
                }
            } catch {
                // ignore
            }
        }
    }
}

class SilentAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    init() {
        engine.attach(playerNode)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        let frames = AVAudioFrameCount(44100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData?[ch]
            for i in 0..<Int(frames) { data?[i] = 0.0 }
        }
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    func play() {
        do {
            if !engine.isRunning { try engine.start() }
            if !playerNode.isPlaying { playerNode.play() }
        } catch {
            print("Failed to start silent audio engine")
        }
    }

    func pause() {
        playerNode.pause()
        engine.pause()
    }

    func restart() {
        playerNode.stop()
        engine.stop()
        play()
    }
}
