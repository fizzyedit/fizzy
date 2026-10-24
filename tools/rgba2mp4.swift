// usage: rgba2mp4 <frames dir> <out.mp4> <fps> [still-stride]
// Frames are f%04d_WxH.rgba (premultiplied RGBA). Writes the video and, every `stride` frames, a PNG still.
import AVFoundation
import AppKit
import CoreVideo

let a = CommandLine.arguments
let dir = a[1], out = a[2], fps = Int32(a[3])!
let stride = a.count > 4 ? Int(a[4])! : 0
let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".rgba") }.sorted()
guard let first = files.first else { fatalError("no frames") }
let dims = first.dropLast(5).split(separator: "_").last!.split(separator: "x").map { Int($0)! }
let W = dims[0] & ~1, H = dims[1] & ~1
try? FileManager.default.removeItem(atPath: out)
let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: out), fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
var t0: Int64 = 0
for (n, f) in files.enumerated() {
    let d = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + f))
    let w0 = Int(f.dropLast(5).split(separator: "_").last!.split(separator: "x")[0])!
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(pb!)
    d.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        for y in 0..<H { for x in 0..<W {
            let i = (y * w0 + x) * 4, o = y * bpr + x * 4
            base[o] = src[i + 2]; base[o + 1] = src[i + 1]; base[o + 2] = src[i]; base[o + 3] = 255
        } }
    }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    let ms = Int64(f.split(separator: "_")[1].dropFirst())!
    if n == 0 { t0 = ms }
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(ms - t0), timescale: 1000))
    if stride > 0 && n % stride == 0 {
        let ci = CIImage(cvPixelBuffer: pb!)
        let rep = NSBitmapImageRep(ciImage: ci)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".mp4", with: String(format: "_still%04d.png", n))))
    }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print("wrote", out, files.count, "frames", W, H)
