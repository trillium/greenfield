import AVFoundation
import SwiftUI

/// Scans a QR code (the `greenfield://add?...` code the installer shows) with the camera and hands the text to `onCode`.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
            // The output delivers on the main queue (set in viewDidLoad).
            MainActor.assumeIsolated {
                guard !delivered, let code else { return }
                delivered = true
                onCode?(code)
            }
        }
    }
}

/// A sheet with the camera and a plain instruction.
struct ScanComputerView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = "Point the camera at the code the installer shows on the computer."

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRScannerView { code in
                    if let url = URL(string: code), let added = model.peers.handle(link: url) {
                        message = "Added \(added.name)."
                        Task {
                            await model.health.refreshAll()
                            model.peers.chooseTheOnlyComputer(health: model.health)
                            dismiss()
                        }
                    } else {
                        message = "That code is not a Greenfield computer. Try the one the installer shows."
                    }
                }
                .ignoresSafeArea()
                Text(message).padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
            }
            .navigationTitle("Scan the computer's code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
