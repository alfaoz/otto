import AppKit
import ScreenCaptureKit
import Vision

enum QR {
    static func decode(png: Data) -> [String] {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
        return decode(img)
    }

    static func decode(_ image: CGImage) -> [String] {
        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap(\.payloadStringValue)
    }

    /// Screenshot every display and read any QR codes on them.
    static func scanScreen() async throws -> [String] {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw OttoError("permission", "otto needs Screen Recording permission to read a QR code from the screen. allow otto in System Settings > Privacy & Security > Screen Recording, then try again")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var found: [String] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = Int(Float(display.width) * filter.pointPixelScale)
            cfg.height = Int(Float(display.height) * filter.pointPixelScale)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            found += decode(img)
        }
        return found
    }
}
