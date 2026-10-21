import CoreImage
import CoreGraphics
import Foundation

/// Renders text as a QR code made of terminal half-blocks, so an installer can show a scannable seed without
/// any other tool. Returns nil if the code cannot be generated.
func terminalQR(_ text: String, border: Int = 2, forDarkTerminal: Bool = false) -> String? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage else { return nil }
    let w = Int(image.extent.width), h = Int(image.extent.height)
    guard w > 0, w == h else { return nil }
    let context = CIContext(options: [.useSoftwareRenderer: true])
    guard let cg = context.createCGImage(image, from: image.extent),
          let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
          let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: space, bitmapInfo: 0) else { return nil }
    bitmap.interpolationQuality = .none
    bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = bitmap.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h)
    func dark(_ x: Int, _ y: Int) -> Bool {
        if x < 0 || y < 0 || x >= w || y >= h { return false }
        return px[(h - 1 - y) * w + x] < 128           // CGContext rows start at the bottom
    }
    var lines: [String] = []
    var y = -border
    while y < h + border {
        var line = ""
        for x in -border..<(w + border) {
            var top = dark(x, y), bottom = dark(x, y + 1)
            // On a dark terminal the "ink" is light, so scanners need light modules on dark: draw the inverse.
            if forDarkTerminal { top.toggle(); bottom.toggle() }
            line += top && bottom ? "█" : top ? "▀" : bottom ? "▄" : " "
        }
        lines.append(line)
        y += 2
    }
    return lines.joined(separator: "\n")
}
