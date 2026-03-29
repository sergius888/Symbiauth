import AppKit
import CoreImage
import Foundation
import Network

// MARK: - TLS Rotation Config (PR2)

/// Lightweight config reader for TLS rotation state
struct TlsRotationConfig: Codable {
    let fp_current: String
    let fp_next: String?
    let cert_path: String
    let staged_cert_path: String?
    let rotation_started_at: UInt64?
    let rotation_window_days: UInt32
}

// MARK: - QR Payload Structure

struct QRPayload: Codable {
    let v: Int = 1
    let svc: String
    let name: String
    let agent_fp: String
    let agent_fp_next: String?  // PR2: Optional next fingerprint for rotation
    let sid: String
    let exp: TimeInterval
    let fallback: String?
}

// MARK: - Pairing Session Management

struct PairingSession {
    let sessionId: String
    let expiresAt: Date
    let fingerprint: String
    
    var isExpired: Bool {
        return Date() > expiresAt
    }
}

class PairingSessionManager {
    private var activeSessions: [String: PairingSession] = [:]
    private let sessionTimeout: TimeInterval = 5 * 60 // 5 minutes
    
    func createSession(fingerprint: String) -> PairingSession {
        // Clean up expired sessions first
        cleanupExpiredSessions()
        
        let sessionId = UUID().uuidString
        let expiresAt = Date().addingTimeInterval(sessionTimeout)
        
        let session = PairingSession(
            sessionId: sessionId,
            expiresAt: expiresAt,
            fingerprint: fingerprint
        )
        
        activeSessions[sessionId] = session
        return session
    }
    
    func validateSession(sessionId: String) -> Bool {
        guard let session = activeSessions[sessionId] else {
            return false
        }
        
        guard !session.isExpired else {
            activeSessions.removeValue(forKey: sessionId)
            return false
        }
        
        // Single-use: remove after validation
        activeSessions.removeValue(forKey: sessionId)
        return true
    }
    
    private func cleanupExpiredSessions() {
        let now = Date()
        activeSessions = activeSessions.filter { _, session in
            return now <= session.expiresAt
        }
    }
}

// MARK: - Utility Functions

func base64url(_ data: Data) -> String {
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func randomToken(bytes: Int = 16) -> String {
    var buffer = [UInt8](repeating: 0, count: bytes)
    let result = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
    guard result == errSecSuccess else {
        // Fallback to UUID if SecRandom fails
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
    return base64url(Data(buffer))
}

func getLocalIPAddress() -> String {
    var address = "127.0.0.1"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    
    guard getifaddrs(&ifaddr) == 0 else { return address }
    guard let firstAddr = ifaddr else { return address }
    
    for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ifptr.pointee
        
        // Check for IPv4 interface
        let addrFamily = interface.ifa_addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {
            
            // Check interface name (skip loopback)
            let name = String(cString: interface.ifa_name)
            if name == "en0" || name.hasPrefix("en") {
                
                // Convert interface address to string
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, socklen_t(0), NI_NUMERICHOST)
                address = String(cString: hostname)
                break
            }
        }
    }
    
    freeifaddrs(ifaddr)
    return address
}

// MARK: - QR Code Generation

func makeQRImage(from json: Data, size: CGFloat = 300) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
        NSLog("QR: Failed to create CIQRCodeGenerator filter")
        return nil
    }
    
    filter.setValue(json, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    
    guard let output = filter.outputImage else {
        NSLog("QR: Failed to generate QR code image")
        return nil
    }
    
    // Scale the QR code to desired size
    let scale = size / output.extent.size.width
    let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    
    // Convert to NSImage
    let rep = NSCIImageRep(ciImage: transformed)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    
    return image
}

// MARK: - QR Display Window

class QRDisplayWindow: NSWindow {
    private let sessionManager: PairingSessionManager
    private var currentSession: PairingSession?
    private var refreshTimer: Timer?
    
    init(sessionManager: PairingSessionManager) {
        self.sessionManager = sessionManager
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        self.title = "Armadillo Pairing"
        self.center()
        self.isReleasedWhenClosed = false
        
        setupUI()
    }
    
    private func setupUI() {
        let containerView = NSView(frame: contentView?.bounds ?? .zero)
        containerView.autoresizingMask = [.width, .height]
        
        // Title label
        let titleLabel = NSTextField(labelWithString: "Scan QR Code to Pair")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 20, y: 420, width: 360, height: 30)
        titleLabel.autoresizingMask = [.width, .minYMargin]
        containerView.addSubview(titleLabel)
        
        // QR code image view
        let imageView = NSImageView()
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 50, y: 120, width: 300, height: 300)
        imageView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        containerView.addSubview(imageView)
        
        // Status label
        let statusLabel = NSTextField(labelWithString: "Generating QR code...")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 80, width: 360, height: 20)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        containerView.addSubview(statusLabel)
        
        // Refresh button
        let refreshButton = NSButton(title: "Generate New QR Code", target: self, action: #selector(refreshQRCode))
        refreshButton.frame = NSRect(x: 140, y: 40, width: 120, height: 30)
        refreshButton.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        containerView.addSubview(refreshButton)
        
        self.contentView = containerView
        
        // Store references for updates
        imageView.identifier = NSUserInterfaceItemIdentifier("qrImageView")
        statusLabel.identifier = NSUserInterfaceItemIdentifier("statusLabel")
    }
    
    func showQRCode(instanceName: String, serviceType: String, fingerprint: String, port: Int) {
        generateAndDisplayQR(instanceName: instanceName, serviceType: serviceType, fingerprint: fingerprint, port: port)
        
        // Set up auto-refresh timer (refresh every 4 minutes, before 5-minute expiry)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4 * 60, repeats: true) { [weak self] _ in
            self?.generateAndDisplayQR(instanceName: instanceName, serviceType: serviceType, fingerprint: fingerprint, port: port)
        }
    }
    
    @objc private func refreshQRCode() {
        guard let session = currentSession else { return }
        
        // Extract info from current session to regenerate
        if let imageView = contentView?.subviews.first(where: { $0.identifier?.rawValue == "qrImageView" }) as? NSImageView,
           let statusLabel = contentView?.subviews.first(where: { $0.identifier?.rawValue == "statusLabel" }) as? NSTextField {
            
            statusLabel.stringValue = "Generating new QR code..."
            
            // We need to store the original parameters to regenerate
            // For now, just show a message
            statusLabel.stringValue = "Click 'Show Pairing QR' in menu to refresh"
        }
    }
    
    private func generateAndDisplayQR(instanceName: String, serviceType: String, fingerprint: String, port: Int) {
        // Create new pairing session
        currentSession = sessionManager.createSession(fingerprint: fingerprint)
        
        guard let session = currentSession else {
            updateStatus("Failed to create pairing session")
            return
        }
        
        // PR2: Load TLS rotation config to check for agent_fp_next
        let configPath = NSHomeDirectory() + "/Library/Application Support/Symbiauth/tls.json"
        var agentFpNext: String? = nil
        
        if let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let config = try? JSONDecoder().decode(TlsRotationConfig.self, from: configData) {
            agentFpNext = config.fp_next
            if let next = agentFpNext {
                NSLog("QR: Rotation in progress, including agent_fp_next: \(next)")
            }
        }
        
        // Create QR payload
        let payload = QRPayload(
            svc: serviceType,
            name: instanceName,
            agent_fp: fingerprint, // fingerprint already includes "sha256:" prefix
            agent_fp_next: agentFpNext,  // PR2: Include next fp only when rotating
            sid: session.sessionId,
            exp: session.expiresAt.timeIntervalSince1970,
            fallback: "\(getLocalIPAddress()):\(port)"
        )
        
        // Generate QR code
        do {
            let jsonData = try JSONEncoder().encode(payload)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "invalid"
            
            NSLog("QR: Generated payload JSON: \(jsonString)")
            NSLog("QR: Payload fingerprint: '\(payload.agent_fp)'")
            if let next = payload.agent_fp_next {
                NSLog("QR: Payload next fingerprint: '\(next)'")
            }
            
            if let qrImage = makeQRImage(from: jsonData, size: 300) {
                updateQRImage(qrImage)
                updateStatus("QR code expires at \(DateFormatter.localizedString(from: session.expiresAt, dateStyle: .none, timeStyle: .medium))")
                
                NSLog("QR: Generated pairing QR code - Session: \(session.sessionId)")
            } else {
                updateStatus("Failed to generate QR code image")
                NSLog("QR: Failed to generate QR code image")
            }
        } catch {
            updateStatus("Failed to encode QR payload: \(error.localizedDescription)")
            NSLog("QR: Failed to encode payload: \(error)")
        }
    }
    
    private func updateQRImage(_ image: NSImage) {
        DispatchQueue.main.async { [weak self] in
            if let imageView = self?.contentView?.subviews.first(where: { $0.identifier?.rawValue == "qrImageView" }) as? NSImageView {
                imageView.image = image
            }
        }
    }
    
    private func updateStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            if let statusLabel = self?.contentView?.subviews.first(where: { $0.identifier?.rawValue == "statusLabel" }) as? NSTextField {
                statusLabel.stringValue = message
            }
        }
    }
    
    override func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        super.close()
    }
    
    deinit {
        refreshTimer?.invalidate()
    }
}