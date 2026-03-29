import Foundation
import CoreBluetooth
import CryptoKit

final class BLETrustServer: NSObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "C7F3A8B0-6E42-4D5A-9A10-4F3A7B0CDE01")
    static let challengeCharUUID = CBUUID(string: "C7F3A8B0-6E42-4D5A-9A10-4F3A7B0CDE02")
    static let proofCharUUID = CBUUID(string: "C7F3A8B0-6E42-4D5A-9A10-4F3A7B0CDE03")

    private let kBle: Data
    private let phoneFp: String
    private let onProofSent: ((Date) -> Void)?
    private var peripheralManager: CBPeripheralManager!
    private var proofCharacteristic: CBMutableCharacteristic?
    private var challengeCharacteristic: CBMutableCharacteristic?
    private var pendingProof: Data?
    private var shouldAdvertise = false
    private var subscribedCentrals: [CBCentral] = []

    init(kBle: Data, phoneFp: String, onProofSent: ((Date) -> Void)? = nil) {
        self.kBle = kBle
        self.phoneFp = phoneFp
        self.onProofSent = onProofSent
        super.init()
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func start() {
        shouldAdvertise = true
        startIfReady()
    }

    func stop(reason: String) {
        shouldAdvertise = false
        pendingProof = nil
        subscribedCentrals.removeAll()
        peripheralManager.stopAdvertising()
        print("[ios] ble.peripheral.stop reason=\(reason)")
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            publishServiceIfNeeded()
            startIfReady()
        } else {
            peripheral.stopAdvertising()
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        if characteristic.uuid == Self.proofCharUUID {
            subscribedCentrals.append(central)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        if characteristic.uuid == Self.proofCharUUID {
            subscribedCentrals.removeAll { $0.identifier == central.identifier }
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        guard request.characteristic.uuid == Self.proofCharUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard let payload = pendingProof else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        request.value = payload
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard request.characteristic.uuid == Self.challengeCharUUID else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
                continue
            }
            guard let value = request.value else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }
            handleChallenge(value)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    private func publishServiceIfNeeded() {
        guard challengeCharacteristic == nil, proofCharacteristic == nil else { return }

        let challenge = CBMutableCharacteristic(
            type: Self.challengeCharUUID,
            properties: [.writeWithoutResponse, .write],
            value: nil,
            permissions: [.writeable]
        )
        let proof = CBMutableCharacteristic(
            type: Self.proofCharUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [challenge, proof]
        peripheralManager.add(service)
        challengeCharacteristic = challenge
        proofCharacteristic = proof
    }

    private func startIfReady() {
        guard shouldAdvertise, peripheralManager.state == .poweredOn else { return }
        if !peripheralManager.isAdvertising {
            let advertisementData: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                CBAdvertisementDataLocalNameKey: "SymbiAuth"
            ]
            peripheralManager.startAdvertising(advertisementData)
            print("[ios] ble.peripheral.start service_uuid=\(Self.serviceUUID.uuidString)")
        }
    }

    private func handleChallenge(_ payload: Data) {
        guard let challenge = decodeChallenge(payload) else {
            print("[ios] gatt.proof.skip reason=invalid_challenge")
            return
        }
        print("[ios] gatt.challenge.recv corr=\(challenge.corrId) nonce=\(challenge.nonceHex) ts=\(Int(Date().timeIntervalSince1970 * 1000))")

        let proof = makeProof(
            nonce: challenge.nonce,
            corrId: challenge.corrId,
            phoneFp: challenge.phoneFp,
            ttlSecs: challenge.ttlSecs
        )
        pendingProof = proof
        if let ch = proofCharacteristic {
            _ = peripheralManager.updateValue(proof, for: ch, onSubscribedCentrals: nil)
        }
        let hmac8 = proof.prefix(4).map { String(format: "%02x", $0) }.joined()
        print("[ios] gatt.proof.send corr=\(challenge.corrId) ttl=\(challenge.ttlSecs) hmac8=\(hmac8)")
        onProofSent?(Date())
    }

    private func makeProof(nonce: Data, corrId: String, phoneFp: String, ttlSecs: UInt64) -> Data {
        var preimage = Data("PROOF".utf8)
        preimage.append(nonce)
        preimage.append(Data(corrId.utf8))
        preimage.append(Data(phoneFp.utf8))
        var ttl = ttlSecs.bigEndian
        preimage.append(Data(bytes: &ttl, count: MemoryLayout<UInt64>.size))
        let mac = HMAC<SHA256>.authenticationCode(for: preimage, using: SymmetricKey(data: kBle))
        return Data(mac)
    }

    private func decodeChallenge(_ data: Data) -> DecodedChallenge? {
        guard data.count >= 16 + 2 + 2 + 8 else { return nil }
        var offset = 0

        let nonce = data.subdata(in: offset ..< offset + 16)
        offset += 16

        guard let corrLen = readU16(data, &offset), data.count >= offset + Int(corrLen) else { return nil }
        let corrData = data.subdata(in: offset ..< offset + Int(corrLen))
        offset += Int(corrLen)
        guard let corrId = String(data: corrData, encoding: .utf8) else { return nil }

        guard let fpLen = readU16(data, &offset), data.count >= offset + Int(fpLen) + 8 else { return nil }
        let fpData = data.subdata(in: offset ..< offset + Int(fpLen))
        offset += Int(fpLen)
        guard let challengePhoneFp = String(data: fpData, encoding: .utf8) else { return nil }

        guard challengePhoneFp == phoneFp else {
            print("[ios] gatt.proof.skip reason=phone_fp_mismatch")
            return nil
        }

        guard let ttlSecs = readU64(data, &offset) else { return nil }

        return DecodedChallenge(
            nonce: nonce,
            corrId: corrId,
            phoneFp: challengePhoneFp,
            ttlSecs: ttlSecs
        )
    }

    private func readU16(_ data: Data, _ offset: inout Int) -> UInt16? {
        guard data.count >= offset + 2 else { return nil }
        let value = data[offset..<offset + 2].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        offset += 2
        return value
    }

    private func readU64(_ data: Data, _ offset: inout Int) -> UInt64? {
        guard data.count >= offset + 8 else { return nil }
        let value = data[offset..<offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        offset += 8
        return value
    }
}

private struct DecodedChallenge {
    let nonce: Data
    let corrId: String
    let phoneFp: String
    let ttlSecs: UInt64

    var nonceHex: String {
        nonce.map { String(format: "%02x", $0) }.joined()
    }
}
