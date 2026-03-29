import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onQRScanned: (QRPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        // No updates needed
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QRScannerDelegate {
        let parent: QRScannerView
        private var didHandleQR = false
        
        init(_ parent: QRScannerView) {
            self.parent = parent
        }
        
        func qrScanner(_ scanner: QRScannerViewController, didScanQR content: String) {
            DispatchQueue.main.async {
                guard !self.didHandleQR else { return }
                self.didHandleQR = true
                
                do {
                    let payload = try QRPayload.parse(from: content)
                    ArmadilloLogger.pairing.info("Successfully parsed QR payload for service: \(payload.svc)")
                    self.parent.onQRScanned(payload)
                    self.parent.dismiss()
                } catch {
                    ArmadilloLogger.pairing.error("Failed to parse QR payload: \(error.localizedDescription)")
                    self.parent.dismiss()
                }
            }
        }
        
        func qrScannerDidCancel(_ scanner: QRScannerViewController) {
            DispatchQueue.main.async {
                self.parent.dismiss()
            }
        }
    }
}

protocol QRScannerDelegate: AnyObject {
    func qrScanner(_ scanner: QRScannerViewController, didScanQR content: String)
    func qrScannerDidCancel(_ scanner: QRScannerViewController)
}

class QRScannerViewController: UIViewController {
    weak var delegate: QRScannerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "com.armadillo.qr.session")
    private var isConfiguring = false
    private var pendingStop = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupUI()
        setupCamera()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            if !session.isRunning {
                session.startRunning()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }
    
    private func setupUI() {
        view.backgroundColor = .black
        
        // Add cancel button
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)
        
        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20)
        ])
        
        // Add instruction label
        let instructionLabel = UILabel()
        instructionLabel.text = "Scan QR code to pair with your Mac"
        instructionLabel.textColor = .white
        instructionLabel.font = .systemFont(ofSize: 16, weight: .medium)
        instructionLabel.textAlignment = .center
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instructionLabel)
        
        NSLayoutConstraint.activate([
            instructionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            instructionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        captureSession = session
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.isConfiguring = true
            session.beginConfiguration()
            
            defer {
                session.commitConfiguration()
                self.isConfiguring = false
                
                if self.pendingStop {
                    session.stopRunning()
                    self.pendingStop = false
                }
            }
            
            guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
                ArmadilloLogger.pairing.error("Failed to get video capture device")
                return
            }
            
            let videoInput: AVCaptureDeviceInput
            
            do {
                videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            } catch {
                ArmadilloLogger.pairing.error("Failed to create video input: \(error.localizedDescription)")
                return
            }
            
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                ArmadilloLogger.pairing.error("Could not add video input to capture session")
                return
            }
            
            let metadataOutput = AVCaptureMetadataOutput()
            
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                
                metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                metadataOutput.metadataObjectTypes = [.qr]
            } else {
                ArmadilloLogger.pairing.error("Could not add metadata output to capture session")
                return
            }
            
            DispatchQueue.main.async {
                let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                previewLayer.frame = self.view.layer.bounds
                previewLayer.videoGravity = .resizeAspectFill
                self.view.layer.addSublayer(previewLayer)
                self.previewLayer = previewLayer
                
                // Bring UI elements to front
                self.view.subviews.forEach { self.view.bringSubviewToFront($0) }
            }
        }
    }
    
    private func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.isConfiguring {
                self.pendingStop = true
                return
            }
            
            if let session = self.captureSession, session.isRunning {
                session.stopRunning()
            }
        }
    }
    
    @objc private func cancelTapped() {
        delegate?.qrScannerDidCancel(self)
    }
    
    // Aggressive cleanup to stop XPC complaints
    private func teardownCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            
            if session.isRunning {
                session.stopRunning()
            }
            
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            
            DispatchQueue.main.async {
                self.previewLayer?.removeFromSuperlayer()
                self.previewLayer = nil
                self.captureSession = nil
            }
        }
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue else { return }
            
            // Aggressive teardown to prevent XPC noise
            teardownCamera()
            
            // Provide haptic feedback
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            
            delegate?.qrScanner(self, didScanQR: stringValue)
        }
    }
}