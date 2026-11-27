import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The little card behind a shared site's QR button: the name, a code to scan, and the link to copy.
struct LANSharePopover: View {
    let host: String
    let url: String
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(host)
                .font(.headline)
            if let code = Self.qrCode(url) {
                Image(nsImage: code)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .accessibilityLabel("QR code for \(url)")
            }
            Text(url)
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
                .textSelection(.enabled)
            Button("Copy Link", action: onCopy)
        }
        .padding(16)
        .frame(width: 220)
    }

    /// A QR code for `text`, at ten points per module so a phone camera reads it from across a desk.
    static func qrCode(_ text: String) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: image.extent.width, height: image.extent.height))
    }
}
