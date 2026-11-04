// Record the screen of one USB-connected iPhone. No camera or audio is captured.
// swift Demo/Tools/RecordDevice.swift out/clip.mov 6
import AVFoundation
import CoreMediaIO
import Foundation

guard CommandLine.arguments.count == 3,
      let seconds = Double(CommandLine.arguments[2]), seconds >= 1, seconds <= 60 else {
    fatalError("Usage: RecordDevice.swift <new-output.mov> <seconds: 1...60>")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: destination.path) else {
    fatalError("Choose a new output file")
}
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
var address = CMIOObjectPropertyAddress(
    mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices),
    mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: 0)
var allow: UInt32 = 1
let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
                                      0, nil, 4, &allow)
guard status == 0 else { fatalError("Cannot enable USB screen devices: \(status)") }
RunLoop.current.run(until: Date().addingTimeInterval(2))
// The USB screen is a muxed device. Continuity Camera is a video device instead.
let screens = AVCaptureDevice.devices(for: .muxed)
guard screens.count == 1 else { fatalError("Connect exactly one unlocked, trusted USB iPhone") }

final class Recorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let writer: AVAssetWriter
    let seconds: Double
    var input: AVAssetWriterInput?
    var start: CMTime?
    var finishing = false
    var frames = 0
    var skipped = 0
    var skippedTimes: [Double] = []

    init(url: URL, seconds: Double) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        self.seconds = seconds
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !finishing, CMSampleBufferDataIsReady(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if start == nil {
            let size = CMVideoFormatDescriptionGetDimensions(CMSampleBufferGetFormatDescription(sample)!)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]
            ])
            video.expectsMediaDataInRealTime = true
            writer.add(video)
            guard writer.startWriting() else { fatalError("Cannot start writer: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: time)
            input = video
            start = time
            print("Recording \(size.width)×\(size.height), video only", terminator: "\n")
            fflush(stdout)
        }
        if CMTimeGetSeconds(time - start!) >= seconds {
            finishing = true
            input!.markAsFinished()
            writer.endSession(atSourceTime: start! + CMTime(seconds: seconds, preferredTimescale: 600))
            writer.finishWriting {
                guard self.writer.status == .completed else {
                    fatalError("Recording failed: \(String(describing: self.writer.error))")
                }
                print("Saved \(self.frames) frames; writer skipped \(self.skipped) input frames")
                if !self.skippedTimes.isEmpty { print("Skipped timestamps:", self.skippedTimes) }
                exit(0)
            }
            return
        }
        if input!.isReadyForMoreMediaData {
            guard input!.append(sample) else { fatalError("Cannot append frame: \(String(describing: writer.error))") }
            frames += 1
        } else {
            skipped += 1
            skippedTimes.append(CMTimeGetSeconds(time - start!))
        }
    }
}

let session = AVCaptureSession()
let deviceInput = try AVCaptureDeviceInput(device: screens[0])
let output = AVCaptureVideoDataOutput()
output.alwaysDiscardsLateVideoFrames = false
let recorder = try Recorder(url: destination, seconds: seconds)
output.setSampleBufferDelegate(recorder, queue: DispatchQueue(label: "org.zhongyr.screen-recording"))
guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
    fatalError("USB screen capture is unavailable")
}
session.addInput(deviceInput)
session.addOutput(output)
session.startRunning()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 20) {
    fatalError("No complete recording received; keep the iPhone connected and unlocked")
}
RunLoop.current.run()
