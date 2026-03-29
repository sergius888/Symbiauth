// STATUS: ACTIVE
// PURPOSE: derives k_ble via ECDH + HKDF — shared key for BLE token HMAC validation
import Foundation
import CryptoKit

enum SessionKeyDerivationError: Error {
    case invalidMacPublic
}

enum SessionKeyDerivation {
    static func deriveSessionKey(macWrapPubSec1Base64: String, sid: String) throws -> Data {
        guard let macPubData = Data(base64Encoded: macWrapPubSec1Base64) else { throw SessionKeyDerivationError.invalidMacPublic }
        // Use ANSI X9.63 (SEC1 uncompressed) initializer explicitly
        let macPub = try P256.KeyAgreement.PublicKey(x963Representation: macPubData)
        let eph = P256.KeyAgreement.PrivateKey()
        let shared = try eph.sharedSecretFromKeyAgreement(with: macPub)
        let salt = sid.data(using: .utf8) ?? Data()
        let info = Data("armadillo/session/v1".utf8)
        let sym = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        // export raw key bytes
        let keyBytes = sym.withUnsafeBytes { Data($0) }
        return keyBytes
    }
    
    static func deriveBleKey(macWrapPubSec1Base64: String, deviceFingerprint: String) throws -> Data {
        guard let macPubData = Data(base64Encoded: macWrapPubSec1Base64) else { throw SessionKeyDerivationError.invalidMacPublic }
        #if DEBUG
        let first = macPubData.first ?? 0xff
        print("[ios] ble.kdbg mac.pub len=\(macPubData.count) first=0x\(String(format: "%02x", first))")
        #endif
        let macPub: P256.KeyAgreement.PublicKey
        do {
            // Use ANSI X9.63 (SEC1 uncompressed) initializer explicitly
            macPub = try P256.KeyAgreement.PublicKey(x963Representation: macPubData)
        } catch {
            #if DEBUG
            print("[ios] ble.kdbg error: PublicKey(rawRepresentation:) \(error.localizedDescription)")
            #endif
            throw error
        }
        let sk: P256.KeyAgreement.PrivateKey
        do {
            sk = try WrapKeyManager.getOrCreatePrivateKey()
        } catch {
            #if DEBUG
            print("[ios] ble.kdbg error: getOrCreatePrivateKey \(error.localizedDescription)")
            #endif
            throw error
        }
        let shared: SharedSecret
        do {
            shared = try sk.sharedSecretFromKeyAgreement(with: macPub)
        } catch {
            #if DEBUG
            print("[ios] ble.kdbg error: sharedSecretFromKeyAgreement \(error.localizedDescription)")
            #endif
            throw error
        }
        
        // salt = SHA256("arm-ble-salt-v1" || fp_bytes_32)
        // Must hex-decode deviceFingerprint first (strip "sha256:" prefix)
        let fpClean = deviceFingerprint.hasPrefix("sha256:") ? 
            String(deviceFingerprint.dropFirst(7)) : deviceFingerprint
        
        // Hex decode
        var fpBytes = Data()
        var index = fpClean.startIndex
        while index < fpClean.endIndex {
            let nextIndex = fpClean.index(index, offsetBy: 2, limitedBy: fpClean.endIndex) ?? fpClean.endIndex
            let byteString = fpClean[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                print("[ios] ble.salt ERROR: invalid hex in deviceFingerprint")
                throw SessionKeyDerivationError.invalidMacPublic
            }
            fpBytes.append(byte)
            index = nextIndex
        }
        
        guard fpBytes.count == 32 else {
            print("[ios] ble.salt ERROR: deviceFingerprint not 32 bytes, got \(fpBytes.count)")
            throw SessionKeyDerivationError.invalidMacPublic
        }
        
        var salt = Data("arm-ble-salt-v1".utf8)
        salt.append(fpBytes)
        salt = Data(SHA256.hash(data: salt))
        let info = Data("arm/ble/v1".utf8)
        
        // Debug: log KDF components (hashes only)
        let sha256_8 = { (data: Data) -> String in
            let h = SHA256.hash(data: data)
            return h.prefix(8).map { String(format:"%02x", $0) }.joined()
        }
        
        // Extract shared secret bytes
        let sharedData = shared.withUnsafeBytes { Data($0) }
        print("[ios] ble.fp_input fp_clean=\(fpClean.prefix(16))... fp_len=\(fpBytes.count)")
        print("[ios] ble.shared.sha256_8=\(sha256_8(sharedData)) shared_len=\(sharedData.count)")
        print("[ios] ble.salt.sha256_8=\(sha256_8(salt)) salt_len=\(salt.count)")
        print("[ios] ble.info=arm/ble/v1")
        
        let sym = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        let kBle = sym.withUnsafeBytes { Data($0) }
        
        print("[ios] ble.k_ble.final.sha256_8=\(sha256_8(kBle)) k_len=\(kBle.count)")
        
        return kBle
    }
}
