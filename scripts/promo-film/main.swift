import AppKit
import Foundation

// Usage: film --shots DIR --brand PNG [--out FILE.mp4] [--music FILE.wav] [--frame SECONDS FILE.png]
var opts: [String: [String]] = [:]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let k = args.removeFirst()
    switch k {
    case "--frame": opts[k] = [args.removeFirst(), args.removeFirst()]
    default: opts[k] = [args.removeFirst()]
    }
}
guard let shots = opts["--shots"]?.first, let brand = opts["--brand"]?.first else {
    FileHandle.standardError.write("usage: film --shots DIR --brand PNG [--out FILE.mp4] [--music FILE.wav] [--frame T FILE.png]\n".data(using: .utf8)!)
    exit(2)
}
_ = NSApplication.shared
let film = Film(shots: shots, brand: brand)

func savePNG(to path: String) {
    let img = film.cg.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

if let f = opts["--frame"] {
    film.frame(at: Double(f[0])!)
    savePNG(to: f[1])
    exit(0)
}

let out = opts["--out"]?.first ?? "vocamac-promo.mp4"
let music = opts["--music"]?.first ?? {
    let path = NSTemporaryDirectory() + "vocamac-promo-music.wav"
    try! Music.writeWAV(Music.render(seconds: 60), to: URL(fileURLWithPath: path))
    return path
}()

let ff = Process()
ff.executableURL = URL(fileURLWithPath: "/usr/bin/env")
ff.arguments = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "\(Int(W))x\(Int(H))", "-framerate", "\(FPS)", "-i", "-",
                "-i", music, "-c:v", "libx264", "-preset", "medium", "-crf", "17", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", out]
let pipe = Pipe()
ff.standardInput = pipe
try ff.run()
let total = 60 * FPS
let bytes = film.cg.bytesPerRow * Int(H)
for n in 0..<total {
    film.frame(at: Double(n) / Double(FPS))
    let data = Data(bytesNoCopy: film.cg.data!, count: bytes, deallocator: .none)
    try pipe.fileHandleForWriting.write(contentsOf: data)
    if n % 300 == 0 { print("frame \(n)/\(total)") }
}
try pipe.fileHandleForWriting.close()
ff.waitUntilExit()
print("wrote \(out)")
