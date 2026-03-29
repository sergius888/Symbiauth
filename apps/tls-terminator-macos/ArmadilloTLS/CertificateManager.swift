import Foundation
import Security
import Crypto
import X509
import SwiftASN1

enum CertificateError: Error {
    case keychainError(OSStatus)
    case certificateGenerationFailed
    case fingerprintCalculationFailed
    case certificateNotFound
    case invalidCertificateData
    case signFailed
    case buildFailed
    case keyExportFailed
}

private let KEY_TAG = "com.armadillo.tls.identity.dev"
private let CERT_LABEL = "Armadillo TLS Dev Identity"
private let DEVICE_ID_KEY = "com.armadillo.tls.deviceId"
private let CERT_DISK_PATH = ("~/.armadillo/server_identity.der" as NSString).expandingTildeInPath

struct SecKeyECDSASigner {
    let secKey: SecKey
    
    func signature<Bytes>(for data: Bytes, using alg: Certificate.SignatureAlgorithm) throws -> [UInt8]
    where Bytes: RandomAccessCollection, Bytes.Element == UInt8 {
        precondition(alg == .ecdsaWithSHA256)
        var e: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(secKey,
                                              .ecdsaSignatureMessageX962SHA256,
                                              Data(data) as CFData,
                                              &e) as Data? else {
            throw CertificateError.signFailed
        }
        return Array(sig)
    }
}

final class CertificateManager {
    // Public entry
    func getOrCreateIdentity() throws -> (SecIdentity, String) {
        // Diagnostics
        diagPrintEnvironment()
        
        // 0) Try disk-persisted certificate first (only if usable for signing)
        if let diskCert = try? loadCertificateFromDisk() {
            print("TLS Identity: Found DER on disk at \(CERT_DISK_PATH)")
            if let id = try? makeIdentity(with: diskCert) {
                if isIdentityUsableForSigning(id) {
                    let fp = try fingerprint(of: id)
                    print("TLS Identity: Reusing certificate from disk, fp=\(fp)")
                    return (id, fp)
                } else {
                    print("TLS Identity: Disk identity not usable for signing (stale ACL); removing DER and continuing")
                    try? deleteCertificateFromDisk()
                }
            } else {
                print("TLS Identity: DER present but no matching private key, will try Keychain")
            }
        } else {
            print("TLS Identity: No DER on disk at \(CERT_DISK_PATH)")
        }
        
        // 1) Prefer an existing identity/certificate in Keychain
        do {
            if let id = try? loadIdentityByLabel(label: CERT_LABEL) {
                if isIdentityUsableForSigning(id) {
                    let fp = try fingerprint(of: id)
                    print("TLS Identity: Reusing certificate from Keychain label '" + CERT_LABEL + "', fp=\(fp)")
                    if let cert = try? extractCertificate(from: id) { try? saveCertificateToDisk(cert) }
                    return (id, fp)
                } else {
                    print("TLS Identity: Keychain identity not usable for signing (stale ACL); deleting private key and continuing")
                    try? deletePrivateKeyByTag(tag: KEY_TAG)
                }
            } else {
                print("TLS Identity: No certificate found in Keychain with label '" + CERT_LABEL + "'")
            }
        }
        
        // 2) Create a new identity (reusing private key if present)
        let id = try createDevIdentity()
        let fp = try fingerprint(of: id)
        print("TLS Identity: Created new certificate, fp=\(fp)")
        return (id, fp)
    }
    
    // Rotate server identity: drop existing key/cert and create a fresh one
    func rotateIdentity() throws -> (SecIdentity, String) {
        // Best-effort cleanup of current artifacts
        try? deleteCertificateFromDisk()
        try? deletePrivateKeyByTag(tag: KEY_TAG)
        // Create new identity
        let id = try createDevIdentity()
        let fp = try fingerprint(of: id)
        return (id, fp)
    }
    
    // --- DEV identity: Keychain P-256 + swift-certificates self-sign ---
    private func createDevIdentity() throws -> SecIdentity {
        // Find or generate keypair in Keychain
        var reusedExistingKey = false
        let priv: SecKey
        let pub: SecKey
        if let found = try? loadPrivateKeyByTag(tag: KEY_TAG), let foundPub = SecKeyCopyPublicKey(found) {
            priv = found
            pub = foundPub
            reusedExistingKey = true
            print("TLS Identity: Reusing existing private key from Keychain (tag=\(KEY_TAG))")
        } else {
            let generated = try makeKeypairInKeychain(tag: KEY_TAG)
            priv = generated.priv
            pub = generated.pub
            print("TLS Identity: Generated new private key in Keychain (tag=\(KEY_TAG))")
        }
        
        // Build + sign self-signed cert with the SAME priv key
        let cn = hostIdentifier()
        print("TLS Identity: Building self-signed certificate CN=\(cn)")
        var cert: SecCertificate
        do {
            cert = try makeSelfSignedCert(priv: priv, pub: pub, cn: cn)
        } catch {
            // If we failed while reusing an old key, delete the key and try once with a fresh key
            if reusedExistingKey {
                print("TLS Identity: Failed to build cert with existing key; deleting stale key and regenerating (error=\(error))")
                try? deletePrivateKeyByTag(tag: KEY_TAG)
                let regenerated = try makeKeypairInKeychain(tag: KEY_TAG)
                print("TLS Identity: Regenerated private key in Keychain (tag=\(KEY_TAG))")
                cert = try makeSelfSignedCert(priv: regenerated.priv, pub: regenerated.pub, cn: cn)
            } else {
                throw error
            }
        }
        
        // Add cert to keychain (idempotent by label)
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: CERT_LABEL,
            kSecValueRef as String: cert
        ]
        let st = SecItemAdd(add as CFDictionary, nil)
        if st == errSecSuccess {
            print("TLS Identity: Stored certificate in Keychain with label '" + CERT_LABEL + "'")
        } else if st == errSecDuplicateItem {
            print("TLS Identity: Certificate already in Keychain under label '" + CERT_LABEL + "' (duplicate)")
        } else {
            print("TLS Identity: Failed to store certificate in Keychain, status=\(st)")
            throw CertificateError.keychainError(st)
        }
        
        // Persist DER to disk for resilience
        try? saveCertificateToDisk(cert)
        print("TLS Identity: Saved DER to \(CERT_DISK_PATH)")
        
        // Create identity from cert
        return try makeIdentity(with: cert)
    }
    
    private func makeKeypairInKeychain(tag: String) throws -> (priv: SecKey, pub: SecKey) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw CertificateError.certificateGenerationFailed
        }
        guard let pub = SecKeyCopyPublicKey(priv) else {
            throw CertificateError.certificateGenerationFailed
        }
        return (priv, pub)
    }
    
    // Restore self-signed certificate builder
    private func makeSelfSignedCert(priv: SecKey, pub: SecKey, cn: String) throws -> SecCertificate {
        // Export public key (x9.63) for swift-certificates
        var e: Unmanaged<CFError>?
        guard let x963 = SecKeyCopyExternalRepresentation(pub, &e) as Data? else {
            throw CertificateError.buildFailed
        }
        let p256Pub = try P256.Signing.PublicKey(x963Representation: x963)
        
        let dn = try DistinguishedName {
            CommonName(cn)
            OrganizationName("Armadillo Dev")
        }
        let now = Date()
        let notAfter = Calendar.current.date(byAdding: .year, value: 3, to: now)!
        
        let cert = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(p256Pub),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: notAfter,
            issuer: dn,
            subject: dn,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Certificate.Extension(oid: [2, 5, 29, 19], critical: true, value: [0x30, 0x03, 0x01, 0x01, 0xFF]) // Basic Constraints CA=true
                Certificate.Extension(oid: [2, 5, 29, 15], critical: true, value: [0x03, 0x02, 0x01, 0x86]) // Key Usage: digitalSignature, keyCertSign
                Certificate.Extension(oid: [2, 5, 29, 37], critical: false, value: [0x30, 0x14, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]) // EKU serverAuth, clientAuth
            },
            issuerPrivateKey: try .init(priv)
        )
        
        var serializer = DER.Serializer()
        try cert.serialize(into: &serializer)
        let der = Data(serializer.serializedBytes)
        guard let secCert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CertificateError.buildFailed
        }
        return secCert
    }
    
    private func loadPrivateKeyByTag(tag: String) throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            return (item as! SecKey)
        }
        print("TLS Identity: Private key not found by tag, status=\(status)")
        return nil
    }
    
    private func deletePrivateKeyByTag(tag: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!
        ]
        SecItemDelete(q as CFDictionary)
    }
    
    private func makeIdentity(with cert: SecCertificate) throws -> SecIdentity {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
        guard status == errSecSuccess, let id = identity else {
            throw CertificateError.certificateNotFound
        }
        return id
    }
    
    private func saveCertificateToDisk(_ cert: SecCertificate) throws {
        let der = SecCertificateCopyData(cert) as Data
        let url = URL(fileURLWithPath: CERT_DISK_PATH)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try der.write(to: url, options: .atomic)
    }
    
    private func deleteCertificateFromDisk() throws {
        let url = URL(fileURLWithPath: CERT_DISK_PATH)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    
    private func loadCertificateFromDisk() throws -> SecCertificate? {
        let url = URL(fileURLWithPath: CERT_DISK_PATH)
        if !FileManager.default.fileExists(atPath: url.path) { return nil }
        let der = try Data(contentsOf: url)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return cert
    }
    
    private func extractCertificate(from identity: SecIdentity) throws -> SecCertificate {
        var cert: SecCertificate?
        let s = SecIdentityCopyCertificate(identity, &cert)
        guard s == errSecSuccess, let cert else { throw CertificateError.certificateNotFound }
        return cert
    }
    
    // --- Helpers ---
    private func loadIdentityByLabel(label: String) throws -> SecIdentity? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true
        ]
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s != errSecSuccess {
            print("TLS Identity: SecItemCopyMatching for certificate label failed, status=\(s)")
            return nil
        }
        let cert = out as! SecCertificate
        // Attempt to build identity (requires matching private key present)
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
        if status != errSecSuccess {
            print("TLS Identity: SecIdentityCreateWithCertificate failed, status=\(status)")
            return nil
        }
        return identity
    }
    
    private func fingerprint(of identity: SecIdentity) throws -> String {
        var cert: SecCertificate?
        let s = SecIdentityCopyCertificate(identity, &cert)
        guard s == errSecSuccess, let cert else { throw CertificateError.certificateNotFound }
        let der = SecCertificateCopyData(cert) as Data
        let digest = SHA256.hash(data: der)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
    
    private func hostIdentifier() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: DEVICE_ID_KEY) {
            return "ArmadilloTLS-\(existing)"
        }
        let newId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        defaults.set(String(newId), forKey: DEVICE_ID_KEY)
        return "ArmadilloTLS-\(newId)"
    }
    
    // MARK: - Client Certificate Enrollment
    
    /// Issue a client certificate from a CSR
    func issueClientCertificate(csrDER: Data) throws -> Data {
        // Parse the CSR
        let csr = try CertificateSigningRequest(derEncoded: Array(csrDER))
        
        // One-shot attempt, then remediate auth/ACL issues by regenerating the CA key and retry once
        func issueOnce() throws -> Data {
            // Get our CA identity for signing
            let (caIdentity, _) = try getOrCreateIdentity()
            
            // Extract CA private key
            var caPrivateKey: SecKey?
            let status = SecIdentityCopyPrivateKey(caIdentity, &caPrivateKey)
            guard status == errSecSuccess, let caKey = caPrivateKey else {
                throw CertificateError.signFailed
            }
            
            // Create client certificate
            let now = Date()
            let notAfter = Calendar.current.date(byAdding: .year, value: 1, to: now)!
            
            let clientCert = try Certificate(
                version: .v3,
                serialNumber: .init(),
                publicKey: csr.publicKey,
                notValidBefore: now.addingTimeInterval(-60),
                notValidAfter: notAfter,
                issuer: try getCASubject(),
                subject: csr.subject,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: Certificate.Extensions {
                    // Client authentication
                    Certificate.Extension(
                        oid: [2, 5, 29, 37], // Extended Key Usage
                        critical: false,
                        value: [0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02] // clientAuth
                    )
                },
                issuerPrivateKey: try .init(caKey)
            )
            
            // Serialize to DER
            var serializer = DER.Serializer()
            try clientCert.serialize(into: &serializer)
            return Data(serializer.serializedBytes)
        }
        
        do {
            return try issueOnce()
        } catch {
            // If the key has an ACL mismatch (e.g., moved app signature), operations may fail with auth denied.
            // Regenerate the CA private key and try once more.
            let errStr = (error as NSError).localizedDescription.lowercased()
            if errStr.contains("auth denied") || errStr.contains("authfailed") || errStr.contains("unsupportedprivatekey") {
                print("Enrollment: signing failed due to key ACL/auth; regenerating CA key and retrying once… error=\(error)")
                try? deletePrivateKeyByTag(tag: KEY_TAG)
                _ = try getOrCreateIdentity()
                return try issueOnce()
            }
            throw error
        }
    }

    /// Issue a client certificate using an already loaded issuer private key (preferred)
    func issueClientCertificate(csrDER: Data, issuerPrivateKey: SecKey) throws -> Data {
        let csr = try CertificateSigningRequest(derEncoded: Array(csrDER))
        let now = Date()
        let notAfter = Calendar.current.date(byAdding: .year, value: 1, to: now)!
        let clientCert = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: csr.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: notAfter,
            issuer: try getCASubject(),
            subject: csr.subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Certificate.Extension(
                    oid: [2, 5, 29, 37],
                    critical: false,
                    value: [0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]
                )
            },
            issuerPrivateKey: try .init(issuerPrivateKey)
        )
        var serializer = DER.Serializer()
        try clientCert.serialize(into: &serializer)
        return Data(serializer.serializedBytes)
    }
    
    private func getCASubject() throws -> DistinguishedName {
        return try DistinguishedName {
            CommonName(hostIdentifier())
            OrganizationName("Armadillo Dev")
        }
    }
    
    private func diagPrintEnvironment() {
        let url = URL(fileURLWithPath: CERT_DISK_PATH)
        print("TLS Identity: Disk path exists=\(FileManager.default.fileExists(atPath: url.path)) path=\(CERT_DISK_PATH)")
        // Probe key by tag
        let _ = try? loadPrivateKeyByTag(tag: KEY_TAG)
        // Probe cert by label
        let _ = try? loadIdentityByLabel(label: CERT_LABEL)
    }
    
    /// Probe that we can extract a private key and perform a signature; if not, the identity is unusable under current code signature/entitlements
    private func isIdentityUsableForSigning(_ identity: SecIdentity) -> Bool {
        var key: SecKey?
        let s = SecIdentityCopyPrivateKey(identity, &key)
        guard s == errSecSuccess, let key else { return false }
        var err: Unmanaged<CFError>?
        let message = "probe".data(using: .utf8)! as CFData
        let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message, &err)
        return sig != nil
    }
}