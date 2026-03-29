import Foundation
import Network
import os.log

class BonjourService: NSObject {
    
    private let logger = Logger(subsystem: "com.armadillo.tls", category: "BonjourService")
    
    private var tlsPort: UInt16
    private let fingerprint: String
    private var netService: NetService?
    private var _instanceName: String?
    private let instanceNameDefaultsKey = "com.armadillo.bonjour.instanceName"
    private var collisionRetryCount: Int = 0
    
    var instanceName: String? {
        return _instanceName
    }
    
    init(fingerprint: String) {
        self.tlsPort = 0 // Will be set when port is known
        self.fingerprint = fingerprint
        super.init()

        // Load stable instance name if present; migrate legacy random names to real machine name.
        if let saved = UserDefaults.standard.string(forKey: instanceNameDefaultsKey), !saved.isEmpty {
            if isLegacyGeneratedName(saved) {
                let migrated = baseMachineName()
                _instanceName = migrated
                UserDefaults.standard.set(migrated, forKey: instanceNameDefaultsKey)
                logger.info("Migrated legacy Bonjour instance name \(saved) -> \(migrated)")
            } else {
                _instanceName = saved
                logger.info("Loaded stable Bonjour instance name: \(saved)")
            }
        }
    }
    
    func publish(port: UInt16) throws {
        // Stop existing service if running
        stop()
        
        // Update port
        self.tlsPort = port
        
        // Generate or reuse instance name
        if _instanceName == nil {
            _instanceName = generateInstanceName(retryIndex: collisionRetryCount)
            if let name = _instanceName {
                UserDefaults.standard.set(name, forKey: instanceNameDefaultsKey)
                logger.info("Saved stable Bonjour instance name: \(name)")
            }
        }
        
        guard let name = _instanceName else {
            throw BonjourError.serviceCreationFailed
        }
        
        // Create TXT record with service metadata
        let txtRecord = createTXTRecord()
        
        // Create NetService
        netService = NetService(domain: "", type: "_armadillo._tcp.", name: name, port: Int32(tlsPort))
        
        guard let service = netService else {
            throw BonjourError.serviceCreationFailed
        }
        
        // Set TXT record
        service.setTXTRecord(txtRecord)
        service.delegate = self
        
        // Publish service
        service.publish()
        collisionRetryCount = 0
        
        logger.info("Publishing Bonjour service: \(name) on port \(self.tlsPort)")
    }
    
    func stop() {
        netService?.stop()
        netService = nil
        logger.info("Stopped Bonjour service")
    }
    
    // MARK: - Private Methods
    
    private func generateInstanceName(retryIndex: Int) -> String {
        let base = baseMachineName()
        if retryIndex <= 0 {
            return base
        }
        let suffix = String(format: "%04X", UInt16.random(in: 0...0xFFFF))
        return "\(base)-\(suffix)"
    }

    private func baseMachineName() -> String {
        let raw = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "SymbiAuth Mac"
        let candidate = (raw?.isEmpty == false) ? raw! : fallback
        return candidate.replacingOccurrences(of: ".", with: "-")
    }

    private func isLegacyGeneratedName(_ value: String) -> Bool {
        let pattern = "^(Swift|Secure|Private|Safe|Protected)(Agent|Guardian|Shield|Vault|Keeper)-[0-9A-F]{4}$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }
    
    private func createTXTRecord() -> Data {
        // Create TXT record with service metadata
        var txtDict: [String: Data] = [:]
        
        // Protocol version
        txtDict["v"] = "1".data(using: .utf8)
        
        // Agent fingerprint (short and full)
        let shortFingerprint = String(fingerprint.suffix(16))
        txtDict["fp"] = shortFingerprint.data(using: .utf8)
        txtDict["fp_full"] = fingerprint.data(using: .utf8)
        
        // TLS port (redundant but useful for validation)
        txtDict["port"] = String(tlsPort).data(using: .utf8)
        
        // Service capabilities
        txtDict["caps"] = "pairing,auth".data(using: .utf8)
        
        // Convert to TXT record format
        return NetService.data(fromTXTRecord: txtDict)
    }
}

// MARK: - NetServiceDelegate

extension BonjourService: NetServiceDelegate {
    
    func netServiceDidPublish(_ sender: NetService) {
        logger.info("Bonjour service published successfully: \(sender.name)")
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        logger.error("Failed to publish Bonjour service: \(errorDict)")
        
        // Try to republish with a different name if there's a conflict
        if let errorCode = errorDict[NetService.errorCode],
           errorCode.intValue == NetService.ErrorCode.collisionError.rawValue {
            logger.info("Name collision detected, retrying with new name")
            
            // Stop current service
            sender.stop()
            
            // Generate new instance name and retry
            collisionRetryCount += 1
            self._instanceName = nil // Force new name generation
            UserDefaults.standard.removeObject(forKey: instanceNameDefaultsKey)
            
            // Retry with new name after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                do {
                    try self.publish(port: self.tlsPort)
                } catch {
                    self.logger.error("Failed to restart service after collision: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func netServiceDidStop(_ sender: NetService) {
        logger.info("Bonjour service stopped: \(sender.name)")
    }
}

// MARK: - Errors

enum BonjourError: Error {
    case serviceCreationFailed
    case publishFailed(String)
}
