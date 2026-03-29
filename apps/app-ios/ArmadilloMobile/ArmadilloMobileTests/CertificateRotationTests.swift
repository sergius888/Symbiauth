import XCTest
@testable import ArmadilloMobile

/// Tests for QR payload decoding and certificate pinning
final class CertificateRotationTests: XCTestCase {
    
    // MARK: - QR Payload Tests
    
    func testQRDecodeWithNextFingerprint() throws {
        let json = """
        {
            "v": 1,
            "agent_fp": "sha256:abc123",
            "agent_fp_next": "sha256:def456",
            "svc": "armadillo",
            "name": "Test Agent",
            "sid": "session-123",
            "exp": 1735689600
        }
        """
        
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(QRPayload.self, from: data)
        
        XCTAssertEqual(payload.v, 1)
        XCTAssertEqual(payload.agent_fp, "sha256:abc123")
        XCTAssertEqual(payload.agent_fp_next, "sha256:def456")
        XCTAssertEqual(payload.svc, "armadillo")
    }
    
    func testQRDecodeWithoutNextFingerprint() throws {
        let json = """
        {
            "v": 1,
            "agent_fp": "sha256:abc123",
            "svc": "armadillo",
            "name": "Test Agent",
            "sid": "session-123",
            "exp": 1735689600
        }
        """
        
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(QRPayload.self, from: data)
        
        XCTAssertEqual(payload.agent_fp, "sha256:abc123")
        XCTAssertNil(payload.agent_fp_next)
    }
    
    /// Test backwards compatibility: old payload ignores unknown keys
    func testQRDecodeWithUnknownKeyIgnored() throws {
        let json = """
        {
            "v": 1,
            "agent_fp": "sha256:abc123",
            "agent_fp_next": "sha256:def456",
            "unknown_field": "should_be_ignored",
            "svc": "armadillo",
            "name": "Test Agent",
            "sid": "session-123",
            "exp": 1735689600
        }
        """
        
        let data = json.data(using: .utf8)!
        
        // Should decode successfully, ignoring unknown_field
        XCTAssertNoThrow(try JSONDecoder().decode(QRPayload.self, from: data))
        
        let payload = try JSONDecoder().decode(QRPayload.self, from: data)
        XCTAssertEqual(payload.agent_fp, "sha256:abc123")
        XCTAssertEqual(payload.agent_fp_next, "sha256:def456")
    }
    
    // MARK: - Certificate Pinner Tests
    
    func testPinnerAcceptsCurrentFingerprint() {
        let pinner = CertificatePinner(
            current: "sha256:abc123",
            next: "sha256:def456"
        )
        
        let mockCert = createMockCertificate(withFingerprint: "sha256:abc123")
        XCTAssertTrue(pinner.validate(mockCert))
    }
    
    func testPinnerAcceptsNextFingerprint() {
        let pinner = CertificatePinner(
            current: "sha256:abc123",
            next: "sha256:def456"
        )
        
        let mockCert = createMockCertificate(withFingerprint: "sha256:def456")
        XCTAssertTrue(pinner.validate(mockCert))
    }
    
    func testPinnerRejectsUnknownFingerprint() {
        let pinner = CertificatePinner(
            current: "sha256:abc123",
            next: "sha256:def456"
        )
        
        let mockCert = createMockCertificate(withFingerprint: "sha256:xyz789")
        XCTAssertFalse(pinner.validate(mockCert))
    }
    
    func testPinnerWithoutNextOnlyAcceptsCurrent() {
        let pinner = CertificatePinner(
            current: "sha256:abc123",
            next: nil
        )
        
        let currentCert = createMockCertificate(withFingerprint: "sha256:abc123")
        let otherCert = createMockCertificate(withFingerprint: "sha256:def456")
        
        XCTAssertTrue(pinner.validate(currentCert))
        XCTAssertFalse(pinner.validate(otherCert))
    }
    
    // MARK: - Helper Methods
    
    /// Creates a mock certificate for testing
    /// Note: In real implementation, this would need actual certificate creation
    /// For now, we'll need to implement proper mocking or use test certificates
    private func createMockCertificate(withFingerprint fingerprint: String) -> SecCertificate {
        // TODO: Implement proper mock certificate creation
        // For now, this is a placeholder that would need real cert data
        fatalError("Mock certificate creation not yet implemented - needs test cert data")
    }
}
