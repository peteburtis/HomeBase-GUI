//
//  PairingScannerView.swift
//  HomeBase-GUI
//

#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

struct PairingScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cameraError: CameraError?

    let onPairingCode: (HomeBaseEndpoint) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let cameraError {
                ContentUnavailableView {
                    Label(cameraError.title, systemImage: "camera.fill")
                } description: {
                    Text(cameraError.message)
                }
                .foregroundStyle(.white)
            } else {
                QRCodeScanner(cameraError: $cameraError) { payload in
                    guard let endpoint = HomeBasePairingCode.endpoint(from: payload) else {
                        return
                    }

                    onPairingCode(endpoint)
                }
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    Label("Scan a HomeBase pairing code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(.bottom, 36)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.65))
                    .padding()
                }
                Spacer()
            }
        }
    }
}

private enum CameraError: Equatable {
    case permissionDenied
    case unavailable

    var title: String {
        switch self {
        case .permissionDenied:
            "Camera Access Required"
        case .unavailable:
            "Camera Unavailable"
        }
    }

    var message: String {
        switch self {
        case .permissionDenied:
            "Allow camera access in Settings to scan a pairing code."
        case .unavailable:
            "This device cannot scan pairing codes right now."
        }
    }
}

private struct QRCodeScanner: UIViewControllerRepresentable {
    @Binding var cameraError: CameraError?
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onCode = onCode
        controller.onError = { error in
            cameraError = error
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

private final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((CameraError) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var hasReportedCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        prepareCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession.stopRunning()
    }

    private func prepareCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStartCapture()
                    } else {
                        self.onError?(.permissionDenied)
                    }
                }
            }
        case .denied, .restricted:
            onError?(.permissionDenied)
        @unknown default:
            onError?(.unavailable)
        }
    }

    private func configureAndStartCapture() {
        guard !isConfigured else {
            captureSession.startRunning()
            return
        }

        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else {
            onError?(.unavailable)
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else {
            onError?(.unavailable)
            return
        }

        captureSession.addInput(input)
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)

        guard metadataOutput.availableMetadataObjectTypes.contains(.qr) else {
            onError?(.unavailable)
            return
        }
        metadataOutput.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
        isConfigured = true
        captureSession.startRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReportedCode else { return }

        for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
            guard code.type == .qr,
                  let payload = code.stringValue,
                  HomeBasePairingCode.endpoint(from: payload) != nil else {
                continue
            }

            hasReportedCode = true
            captureSession.stopRunning()
            onCode?(payload)
            return
        }
    }
}
#endif
