import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeImage {
    /// Renders `text` as a crisp QR code of about `side` points; nil if CoreImage cannot encode it.
    static func make(from text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }

        // Whole-pixel upscaling keeps module edges sharp; Retina gets twice the modules' pixels.
        let scale = max(1, (side * 2 / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2)
        )
    }
}
