// Frame-accurate scene extractor: samples the take at true (player)
// timeline positions via AVFoundation, emitting a single 30 fps PNG
// sequence = the trimmed & concatenated base video. ffmpeg's fps/trim
// filters mis-read simulator VFR timestamps; AVFoundation is the
// authority on what players actually show.
import AVFoundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: extract_frames <in.mov> <outdir> <start:end> [start:end ...]")
    exit(1)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let outDir = args[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .positiveInfinity
gen.requestedTimeToleranceAfter = .zero

var times: [NSValue] = []
for window in args[3...] {
    let parts = window.split(separator: ":").map { Double($0)! }
    var t = parts[0]
    while t < parts[1] - 1.0 / 60 {
        times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
        t += 1.0 / 30
    }
}
print("frames to extract: \(times.count)")

var index = 0
let group = DispatchGroup()
group.enter()
gen.generateCGImagesAsynchronously(forTimes: times) { _, cg, _, result, error in
    index += 1
    if let cg {
        let rep = NSBitmapImageRep(cgImage: cg)
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: String(format: "%@/f-%05d.png", outDir, index)))
    } else {
        print("frame \(index) failed: \(error?.localizedDescription ?? "\(result)")")
    }
    if index == times.count { group.leave() }
}
group.wait()
print("done")
