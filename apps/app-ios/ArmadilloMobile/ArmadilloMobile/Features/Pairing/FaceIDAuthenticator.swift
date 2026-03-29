import Foundation
import LocalAuthentication

/// FaceID authentication wrapper for auth proof generation
/// TODO: Implement full biometric authentication + cryptographic signing
enum FaceIDAuthenticator {
    enum AuthError: Error {
        case biometryNotEnrolled
        case authenticationFailed(Error)
        case cancelled
    }
    
    /// Generate an authentication proof using Face ID
    /// - Parameters:
    ///   - corrId: Correlation ID from auth.request
    ///   - clientIdentity: Client identity (SecIdentity) for signing
    /// - Returns: Auth proof message dictionary
    static func generateAuthProof(
        corrId: String,
        clientIdentity: SecIdentity
    ) async throws -> [String: Any] {
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if let error = error {
                throw AuthError.authenticationFailed(error)
            }
            throw AuthError.biometryNotEnrolled
        }
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Approve authentication request"
            )
            
            guard success else {
                throw AuthError.cancelled
            }

            // M1.5: Build auth.proof payload expected by the agent
            let now = UInt64(Date().timeIntervalSince1970)
            let nonceData = UUID().uuidString.data(using: .utf8) ?? Data()
            let nonceB64 = nonceData.base64EncodedString()

            return [
                "type": "auth.proof",
                "corr_id": corrId,
                "ts": now,
                "nonce_b64": nonceB64,
                // Signature optional for now; agent accepts empty sig_b64
                "sig_b64": ""
            ]
        } catch {
            throw AuthError.authenticationFailed(error)
        }
    }
}
