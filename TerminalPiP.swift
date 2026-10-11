import SwiftUI
import AVKit
import AVFoundation
import CoreVideo

/// Opt-in, read-only video rendering of the terminal. Not an interactive overlay
/// and not a promise that iOS/LiveContainer will grant background execution.
final class TerminalPiP: NSObject, ObservableObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    static let shared = TerminalPiP()
    let displayLayer = AVSampleBufferDisplayLayer()
    @Published private(set) var status = "Preview off"
    @Published private(set) var active = false
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var observation: NSKeyValueObservation?
    private var provider: (() -> UIImage?)?
    @Published private(set) var possible = false
    var restore: (() -> Void)?

    func configure(provider: @escaping () -> UIImage?) {
        self.provider = provider
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.requiresLinearPlayback = true
        // Explicit user action only; never start PiP just because the app backgrounds.
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        controller = pip
        observation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            DispatchQueue.main.async { self?.possible = pip.isPictureInPicturePossible }
        }
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            displayLayer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
        }
    }
    func beginPreview() {
        guard timer == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            // No silent audio playback; only the visible terminal video is produced.
            status = "Preparing preview…"
            frame()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.frame() }
        } catch { status = error.localizedDescription }
    }
    func start() {
        guard possible else { status = "PiP unavailable. Keep the preview visible and try again."; return }
        controller?.startPictureInPicture()
    }
    func stop() {
        controller?.stopPictureInPicture()
        endFrames()
    }
    private func endFrames() {
        timer?.invalidate(); timer = nil
        active = false; status = "Preview off"
        displayLayer.flushAndRemoveImage()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    private func frame() {
        guard let image = provider?()?.cgImage else { return }
        let width = 960, height = 540
        var pixel: CVPixelBuffer?
        let options: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                     kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                                     kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options as CFDictionary, &pixel) == kCVReturnSuccess,
              let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
            context.setFillColor(UIColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            context.draw(image, in: CGRect(x: (CGFloat(width)-w)/2, y: (CGFloat(height)-h)/2, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        if displayLayer.isReadyForMoreMediaData { displayLayer.enqueue(sample) }
        if !active { status = possible ? "Preview ready · tap Start PiP" : "Waiting for iOS PiP availability…" }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if !playing { stop() }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { active = true; status = "PiP active · background runtime is system-controlled" }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { endFrames() }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { endFrames(); status = error.localizedDescription }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { restore?(); completionHandler(true) }
}

struct PiPPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewView { PreviewView() }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(TerminalPiP.shared.displayLayer)
            backgroundColor = .black
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); TerminalPiP.shared.displayLayer.frame = bounds }
    }
}
