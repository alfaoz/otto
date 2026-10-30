import AVFoundation
import SwiftUI
import Vision

/// Live camera preview that reports every QR code it sees (each payload once).
struct CameraScanner: NSViewRepresentable {
    let found: (String) -> Void

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        context.coordinator.start(in: v)
        return v
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class PreviewView: NSView {
        let layerPreview = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layerPreview.videoGravity = .resizeAspectFill
            layer?.addSublayer(layerPreview)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            layerPreview.frame = bounds
        }
    }

    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let found: (String) -> Void
        let session = AVCaptureSession()
        let queue = DispatchQueue(label: "otto.camera")
        var seen = Set<String>()
        var frame = 0

        init(found: @escaping (String) -> Void) { self.found = found }

        func start(in view: PreviewView) {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                guard ok else { return }
                self.queue.async {
                    guard let device = AVCaptureDevice.default(for: .video),
                          let input = try? AVCaptureDeviceInput(device: device),
                          self.session.canAddInput(input) else { return }
                    self.session.beginConfiguration()
                    self.session.addInput(input)
                    let out = AVCaptureVideoDataOutput()
                    out.setSampleBufferDelegate(self, queue: self.queue)
                    if self.session.canAddOutput(out) { self.session.addOutput(out) }
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { view.layerPreview.session = self.session }
                    self.session.startRunning()
                }
            }
        }

        func stop() {
            queue.async { self.session.stopRunning() }
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            frame += 1
            guard frame % 5 == 0, let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let req = VNDetectBarcodesRequest()
            req.symbologies = [.qr]
            try? VNImageRequestHandler(cvPixelBuffer: px).perform([req])
            for p in (req.results ?? []).compactMap(\.payloadStringValue) where !seen.contains(p) {
                seen.insert(p)
                DispatchQueue.main.async { self.found(p) }
            }
        }
    }
}

/// A camera panel with a frame and a hint, used in a sheet.
struct CameraSheet: View {
    let hint: String
    let found: (String) -> Void
    let done: () -> Void
    @State private var count = 0

    var body: some View {
        VStack(spacing: 12) {
            CameraScanner { p in
                count += 1
                found(p)
            }
            .frame(width: 420, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
            Text(hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(count == 0 ? "looking for a QR code…" : "read \(count) QR code\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done", action: done).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 456)
    }
}
