import Foundation

let output = "[ 50%] /sdcard/Movies/large_video_dummy_1.mp4"
let regex = try! NSRegularExpression(pattern: "\\[\\s*(\\d+)%\\]", options: [])
if let match = regex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
    if let range = Range(match.range(at: 1), in: output) {
        let percentString = output[range]
        if let percent = Int(percentString) {
            print("Percentage: \(percent)")
        }
    }
}
