import Foundation
import Security
import CryptoKit

enum SimpleClientIdentity {
    private static let keyTag = "com.armadillo.client.key".data(using: .utf8)!
    private static let certLabel = "Armadillo Client Certificate"
    private static let certIssuedAtKey = "com.armadillo.client.cert_issued_at"
    private static let certExpiresAtKey = "com.armadillo.client.cert_expires_at"
    
    static func getOrCreate(host: String = "192.168.1.2", expectedFingerprint: String? = nil) throws -> SecIdentity {
        // Try existing identity first
        if let existing = try? loadExistingIdentity() {
            ArmadilloLogger.security.info("Using existing client identity")
            // Check if renewal is needed (<10% lifetime remaining)
            if shouldRenew(identity: existing, renewThresholdFraction: 0.10) {
                ArmadilloLogger.security.info("Client identity nearing expiry; renewing via CSR enrollment")
                return try renewExistingIdentity(existingIdentity: existing, host: host, expectedFingerprint: expectedFingerprint)
            }
            return existing
        }
        
        ArmadilloLogger.security.info("Generating new client identity via CSR enrollment")
        
        // 1. Generate P-256 key
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &error) else {
            throw error?.takeRetainedValue() as Error? ?? SimpleClientIdentityError.keyGenerationFailed
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SimpleClientIdentityError.keyGenerationFailed
        }
        
        // 2. Create CSR using proper DER encoding
        let csrDER = try createCSR(privateKey: privateKey, publicKey: publicKey, commonName: "Armadillo iOS Client")
        
        // 3. Call enroll endpoint
        let enrollURL = URL(string: "https://\(host):8444/enroll")!
        let fingerprintHex = expectedFingerprint?.replacingOccurrences(of: "sha256:", with: "") ?? ""
        let certDER = try EnrollAPI.enroll(csrDER: csrDER, serverURL: enrollURL, expectedFingerprintHex: fingerprintHex)
        
        // 4. Store certificate
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw SimpleClientIdentityError.certificateCreationFailed
        }
        // Ensure old cert with the same label is removed before adding
        deleteCertificateByLabel()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            throw SimpleClientIdentityError.certificateStoreFailed(status)
        }
        
        // 5. Create SecIdentity
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecValueRef as String: certificate
        ]
        var identityResult: CFTypeRef?
        let identityStatus = SecItemCopyMatching(identityQuery as CFDictionary, &identityResult)
        guard identityStatus == errSecSuccess, let identity = identityResult else {
            throw SimpleClientIdentityError.identityCreationFailed
        }
        // Record validity window (assume 1 year as per server config)
        let now = Date()
        let oneYear: TimeInterval = 365 * 24 * 60 * 60
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: certIssuedAtKey)
        UserDefaults.standard.set(now.addingTimeInterval(oneYear).timeIntervalSince1970, forKey: certExpiresAtKey)
        
        return (identity as! SecIdentity)
    }
    
    static func loadExistingIdentity() throws -> SecIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrLabel as String: certLabel
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identity = result else {
            throw SimpleClientIdentityError.identityNotFound
        }
        return (identity as! SecIdentity)
    }
    
    // MARK: - CSR Construction (PKCS#10)
    
    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes = withUnsafeBytes(of: UInt32(length).bigEndian, Array.init)
        while bytes.first == 0 { bytes.removeFirst() }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    
    private static func derTLV(tag: UInt8, value: [UInt8]) -> [UInt8] {
        return [tag] + derLength(value.count) + value
    }
    
    private static func derOID(_ oid: [UInt64]) -> [UInt8] {
        // Basic OID encoder
        precondition(oid.count >= 2)
        var out: [UInt8] = [UInt8(oid[0] * 40 + oid[1])]
        for component in oid.dropFirst(2) {
            var stack: [UInt8] = []
            var val = component
            repeat {
                stack.append(UInt8(val & 0x7F))
                val >>= 7
            } while val > 0
            for i in stack.indices.reversed() {
                let b = stack[i] | (i == 0 ? 0x00 : 0x80)
                out.append(b)
            }
        }
        return derTLV(tag: 0x06, value: out)
    }
    
    private static func derUTF8String(_ s: String) -> [UInt8] {
        derTLV(tag: 0x0C, value: [UInt8](s.utf8))
    }
    
    private static func buildName(commonName: String) -> [UInt8] {
        // Name ::= SEQUENCE of RDNs
        // RDN = SET of SEQUENCE { OID(2.5.4.3), UTF8String }
        let cnOID = derOID([2,5,4,3])
        let cnVal = derUTF8String(commonName)
        let attr = derTLV(tag: 0x30, value: cnOID + cnVal)
        let rdn = derTLV(tag: 0x31, value: attr)
        return derTLV(tag: 0x30, value: rdn)
    }
    
    private static func buildSPKI(publicKey: SecKey) throws -> [UInt8] {
        // SubjectPublicKeyInfo
        // AlgorithmIdentifier = SEQUENCE { ecPublicKey OID, prime256v1 OID }
        let alg = derTLV(tag: 0x30, value:
            derOID([1,2,840,10045,2,1]) + // ecPublicKey
            derOID([1,2,840,10045,3,1,7]) // prime256v1
        )
        
        // Public key bytes in uncompressed form
        var error: Unmanaged<CFError>?
        guard let pubData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() as Error? ?? SimpleClientIdentityError.keyGenerationFailed
        }
        // BIT STRING = 0x03 len 0x00 || keyBytes
        let bitString = [UInt8(0x00)] + [UInt8](pubData)
        let spk = derTLV(tag: 0x03, value: bitString)
        
        return derTLV(tag: 0x30, value: alg + spk)
    }
    
    private static func createCSR(privateKey: SecKey, publicKey: SecKey, commonName: String) throws -> Data {
        // CertificationRequestInfo ::= SEQUENCE { version, subject, subjectPKInfo, attributes }
        let version = derTLV(tag: 0x02, value: [0x00])
        let subject = buildName(commonName: commonName)
        let spki = try buildSPKI(publicKey: publicKey)
        let attributesEmpty: [UInt8] = [0xA0, 0x00] // [0] IMPLICIT SET OF Attribute (empty)
        let cri = derTLV(tag: 0x30, value: version + subject + spki + attributesEmpty)
        
        // Sign cri with ECDSA-SHA256 (X9.62 DER signature)
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey,
                                              .ecdsaSignatureMessageX962SHA256,
                                              Data(cri) as CFData,
                                              &error) as Data? else {
            throw error?.takeRetainedValue() as Error? ?? SimpleClientIdentityError.certificateCreationFailed
        }
        // signatureAlgorithm = SEQUENCE { ecdsa-with-SHA256 OID }
        let sigAlg = derTLV(tag: 0x30, value: derOID([1,2,840,10045,4,3,2]))
        // signature BIT STRING: 0x00 + DER-encoded ECDSA signature
        let sigBitString = derTLV(tag: 0x03, value: [0x00] + [UInt8](sig))
        
        // Final CSR = SEQUENCE { cri, sigAlg, sig }
        let csr = derTLV(tag: 0x30, value: [UInt8](cri) + sigAlg + sigBitString)
        return Data(csr)
    }
    
    // MARK: - Renewal helpers
    private static func renewExistingIdentity(existingIdentity: SecIdentity, host: String, expectedFingerprint: String?) throws -> SecIdentity {
        // Prefer reusing the existing private key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnRef as String: true
        ]
        var keyItem: CFTypeRef?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyItem)
        let privateKey: SecKey
        if keyStatus == errSecSuccess, let k = keyItem {
            privateKey = (k as! SecKey)
        } else {
            // Fallback: generate a new key if missing
            let keyAttrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: keyTag,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                ]
            ]
            var err: Unmanaged<CFError>?
            guard let newKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &err) else {
                throw err?.takeRetainedValue() as Error? ?? SimpleClientIdentityError.keyGenerationFailed
            }
            privateKey = newKey
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SimpleClientIdentityError.keyGenerationFailed
        }
        let csrDER = try createCSR(privateKey: privateKey, publicKey: publicKey, commonName: "Armadillo iOS Client")
        let enrollURL = URL(string: "https://\(host):8444/enroll")!
        let fingerprintHex = expectedFingerprint?.replacingOccurrences(of: "sha256:", with: "") ?? ""
        let certDER = try EnrollAPI.enroll(csrDER: csrDER, serverURL: enrollURL, expectedFingerprintHex: fingerprintHex)
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw SimpleClientIdentityError.certificateCreationFailed
        }
        // Replace certificate
        deleteCertificateByLabel()
        let addAttrs: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            throw SimpleClientIdentityError.certificateStoreFailed(addStatus)
        }
        // Build identity from new cert
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecValueRef as String: certificate
        ]
        var identityResult: CFTypeRef?
        let identityStatus = SecItemCopyMatching(identityQuery as CFDictionary, &identityResult)
        guard identityStatus == errSecSuccess, let identity = identityResult else {
            throw SimpleClientIdentityError.identityCreationFailed
        }
        // Update stored validity (assume 1 year as issued by server)
        let now = Date()
        let oneYear: TimeInterval = 365 * 24 * 60 * 60
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: certIssuedAtKey)
        UserDefaults.standard.set(now.addingTimeInterval(oneYear).timeIntervalSince1970, forKey: certExpiresAtKey)
        
        return (identity as! SecIdentity)
    }
    
    private static func deleteCertificateByLabel() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel
        ]
        SecItemDelete(q as CFDictionary)
    }
    
    private static func shouldRenew(identity: SecIdentity, renewThresholdFraction: Double) -> Bool {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let exp = defaults.double(forKey: certExpiresAtKey)
        let iss = defaults.double(forKey: certIssuedAtKey)
        guard exp > 0 else { return false }
        let total = (iss > 0) ? (exp - iss) : (365 * 24 * 60 * 60)
        if total <= 0 { return false }
        let remaining = exp - now
        let fraction = remaining / total
        return fraction <= renewThresholdFraction
    }
}

enum EnrollAPI {
    // * Call with the fingerprint from QR (hex lowercase, sha256 of leaf cert)
    static func enroll(csrDER: Data, serverURL: URL, expectedFingerprintHex: String) throws -> Data {
        let delegate = PinnedSessionDelegate(expectedFingerprintHex: expectedFingerprintHex) // *
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil) // *
        
        var request = URLRequest(url: serverURL)
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("application/pkcs10", forHTTPHeaderField: "Content-Type")
        request.setValue(String(csrDER.count), forHTTPHeaderField: "Content-Length")
        request.httpMethod = "POST"
        request.httpBody = csrDER
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>!
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                result = .failure(error)
            } else if let data = data,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200 {
                result = .success(data)
            } else {
                result = .failure(SimpleClientIdentityError.enrollmentFailed)
            }
            semaphore.signal()
        }.resume()
        
        semaphore.wait()
        return try result.get()
    }
}

// * URLSessionDelegate with certificate pinning for enrollment
final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    private let expected: String
    init(expectedFingerprintHex: String) { self.expected = expectedFingerprintHex.lowercased() }
    
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Compute SHA-256 fingerprint of the leaf certificate DER
        let der = SecCertificateCopyData(leaf) as Data
        let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined() // *
        print("Enroll pin: computed=\(fp) expected=\(expected)") // * TEMP: remove after success
        
        if fp == expected {
            completionHandler(.useCredential, URLCredential(trust: trust)) // *
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

enum SimpleClientIdentityError: LocalizedError {
    case keyGenerationFailed
    case certificateCreationFailed
    case certificateStoreFailed(OSStatus)
    case identityCreationFailed
    case identityNotFound
    case enrollmentFailed
    
    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate client key pair"
        case .certificateCreationFailed:
            return "Failed to create client certificate"
        case .certificateStoreFailed(let status):
            return "Failed to store certificate: \(status)"
        case .identityCreationFailed:
            return "Failed to create client identity"
        case .identityNotFound:
            return "Client identity not found"
        case .enrollmentFailed:
            return "Failed to enroll certificate with server"
        }
    }
}