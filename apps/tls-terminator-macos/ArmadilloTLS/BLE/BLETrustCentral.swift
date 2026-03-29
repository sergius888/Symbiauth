import Foundation
import CoreBluetooth
import Security
import os.log

final class BLETrustCentral: NSObject {
    struct TrustStateSnapshot {
        let event: String
        let trustId: String?
        let mode: String?
        let trustUntilMs: UInt64?
        let deadlineMs: UInt64?
        let reason: String?
    }

    private let logger = Logger(subsystem: "com.armadillo.tls", category: "BLETrustCentral")
    private let socketBridge: UnixSocketBridge
    private let phoneFp: String
    private var mode: String
    private var ttlSecs: UInt64
    private let onEvent: (([String: Any]) -> Void)?
    private let presenceTimeoutSecs: TimeInterval

    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var challengeCharacteristic: CBCharacteristic?
    private var proofCharacteristic: CBCharacteristic?

    private var connectInFlight = false
    private var challengeInFlight = false
    private var proofSubscribed = false
    private var currentSignalPresent = false
    private var latestTrustId: String?

    private var activeCorrId: String?
    private var activeNonce: Data?
    private var activeChallengeTsMs: UInt64?
    private var proofTimeoutItem: DispatchWorkItem?
    private var keepaliveTimer: DispatchSourceTimer?

    private static let serviceUUID = CBUUID(string: "C7F3A8B0-6E42-4D5A-9A10-4F3A7B0CDE01")
    private static let challengeUUID = CBUUID(string: "C7F3A8B0-6E42-4D5A-9A10-4F3A7B0CDE02")
    private static let proofUUID = CBUUID(string: "C7F3A8B0-6E42-4D5A-9A10-4F3A7B0CDE03")

    private static func normalizeMode(_ raw: String) -> String {
        switch raw.lowercased() {
        case "strict", "background_ttl", "office":
            return raw.lowercased()
        default:
            return "background_ttl"
        }
    }

    init(socketBridge: UnixSocketBridge,
         phoneFp: String,
         mode: String,
         ttlSecs: UInt64,
         onEvent: (([String: Any]) -> Void)? = nil) {
        self.socketBridge = socketBridge
        self.phoneFp = phoneFp
        self.mode = Self.normalizeMode(mode)
        self.ttlSecs = ttlSecs
        self.onEvent = onEvent
        let rawTimeout = ProcessInfo.processInfo.environment["ARM_TRUST_PRESENCE_TIMEOUT_SECS"]
            .flatMap(Double.init) ?? 12
        self.presenceTimeoutSecs = min(max(rawTimeout, 5), 60)
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        emit(["event": "ble.trust_central.start", "phone_fp": phoneFp])
    }

    func updateRuntimeConfig(mode: String, ttlSecs: UInt64) {
        self.mode = Self.normalizeMode(mode)
        self.ttlSecs = ttlSecs
        emit([
            "event": "ble.trust_central.config_updated",
            "mode": self.mode,
            "ttl_secs": self.ttlSecs
        ])
    }

    func requestImmediateProof(reason: String) {
        emit([
            "event": "ble.trust_central.proof_requested",
            "reason": reason
        ])
        beginHandshakeIfReady()
    }

    func ingestTrustEvent(_ json: [String: Any]) -> TrustStateSnapshot? {
        guard let event = json["event"] as? String else { return nil }
        let trustId = json["trust_id"] as? String
        if let trustId {
            latestTrustId = trustId
        }
        if event == "revoked" {
            latestTrustId = nil
            // When revoke is driven by control plane (trust.revoke), CoreBluetooth may keep
            // a stale peripheral connection for tens of seconds. Force a clean BLE cycle so
            // the next foreground session can handshake immediately.
            forceResetAndRescan(reason: "trust_revoked")
        } else if event == "signal_lost" {
            // In background_ttl/office we can enter degraded state without revoke. If central
            // keeps a stale link, returning foreground may not retrigger proof promptly.
            // Reset here to guarantee quick reconnect/challenge on resume.
            forceResetAndRescan(reason: "trust_signal_lost")
        }
        return TrustStateSnapshot(
            event: event,
            trustId: trustId,
            mode: json["mode"] as? String,
            trustUntilMs: parseU64(json["trust_until_ms"]),
            deadlineMs: parseU64(json["deadline_ms"]),
            reason: json["reason"] as? String
        )
    }

    private func maybeStartScan() {
        guard centralManager.state == .poweredOn else { return }
        guard !connectInFlight, targetPeripheral == nil else { return }
        emit(["event": "ble.scan.start", "service_uuid": Self.serviceUUID.uuidString])
        centralManager.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func stopScan() {
        centralManager.stopScan()
    }

    private func beginHandshakeIfReady() {
        guard let peripheral = targetPeripheral,
              let challengeChar = challengeCharacteristic,
              proofSubscribed,
              !challengeInFlight else {
            return
        }

        let corr = makeCorrId()
        guard let nonce = randomNonce(count: 16) else {
            emit(["event": "trust.challenge.skip", "reason": "nonce_generation_failed"])
            return
        }
        guard let payload = encodeChallenge(nonce: nonce, corrId: corr, phoneFp: phoneFp, ttlSecs: ttlSecs) else {
            emit(["event": "trust.challenge.skip", "reason": "challenge_encode_failed", "corr": corr])
            return
        }

        challengeInFlight = true
        activeCorrId = corr
        activeNonce = nonce
        activeChallengeTsMs = nowMs()

        emit([
            "event": "trust.challenge.send",
            "corr": corr,
            "nonce": nonce.hex,
            "ttl_req": ttlSecs,
            "mode": mode,
            "phone_fp": phoneFp
        ])

        peripheral.writeValue(payload, for: challengeChar, type: .withResponse)
        scheduleProofTimeout(corr: corr)
    }

    private func scheduleProofTimeout(corr: String) {
        proofTimeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.challengeInFlight, self.activeCorrId == corr else { return }
            self.emit(["event": "trust.proof.timeout", "corr": corr, "action": "signal_lost"])
            self.sendSignalLost(reason: "proof_timeout")
            self.forceResetAndRescan(reason: "proof_timeout")
        }
        proofTimeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3), execute: item)
    }

    private func startKeepaliveTimer() {
        stopKeepaliveTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + presenceTimeoutSecs, repeating: presenceTimeoutSecs)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.currentSignalPresent else { return }
            self.emit([
                "event": "trust.keepalive.tick",
                "interval_secs": self.presenceTimeoutSecs
            ])
            self.beginHandshakeIfReady()
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func stopKeepaliveTimer() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    private func forwardProof(_ proofData: Data) {
        guard challengeInFlight,
              let corr = activeCorrId,
              let nonce = activeNonce,
              let challengeTs = activeChallengeTsMs else {
            return
        }
        challengeInFlight = false
        proofTimeoutItem?.cancel()

        let req: [String: Any] = [
            "type": "trust.verify_request",
            "v": 1,
            "origin": "macos",
            "corr_id": corr,
            "ts_ms": nowMs(),
            "phone_fp": phoneFp,
            "mode": mode,
            "ttl_secs": ttlSecs,
            "challenge": [
                "nonce_b64": nonce.base64EncodedString(),
                "challenge_ts_ms": challengeTs
            ],
            "proof": [
                "proof_b64": proofData.base64EncodedString(),
                "proof_ts_ms": nowMs()
            ],
            "transport": [
                "service_uuid": Self.serviceUUID.uuidString,
                "ble_id": targetPeripheral?.identifier.uuidString ?? ""
            ]
        ]

        socketBridge.send(json: req) { [weak self] responseData in
            guard let self else { return }
            guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                self.emit(["event": "trust.verify_response.parse_error", "corr": corr])
                return
            }

            if let grant = response["grant"] as? [String: Any], (response["ok"] as? Bool) == true {
                self.latestTrustId = grant["trust_id"] as? String
                self.emit([
                    "event": "trust.proof.ok",
                    "corr": corr,
                    "trust_id": self.latestTrustId ?? "",
                    "ttl_secs_effective": grant["ttl_secs_effective"] ?? 0
                ])
            } else {
                let deny = response["deny"] as? [String: Any]
                self.emit([
                    "event": "trust.proof.fail",
                    "corr": corr,
                    "reason": deny?["reason"] as? String ?? "unknown"
                ])
            }
        }
    }

    private func sendSignalPresent() {
        guard !currentSignalPresent else { return }
        currentSignalPresent = true
        let corr = "sp_\(makeCorrId())"
        let trustIdField: Any = latestTrustId ?? NSNull()
        let payload: [String: Any] = [
            "type": "trust.signal_present",
            "v": 1,
            "origin": "macos",
            "corr_id": corr,
            "ts_ms": nowMs(),
            "phone_fp": phoneFp,
            "trust_id": trustIdField
        ]
        socketBridge.send(json: payload) { _ in }
        emit(["event": "trust.signal_present", "corr": corr, "phone_fp": phoneFp])
    }

    private func sendSignalLost(reason: String) {
        guard currentSignalPresent else { return }
        currentSignalPresent = false
        challengeInFlight = false
        proofTimeoutItem?.cancel()

        let corr = "sl_\(makeCorrId())"
        let trustIdField: Any = latestTrustId ?? NSNull()
        let payload: [String: Any] = [
            "type": "trust.signal_lost",
            "v": 1,
            "origin": "macos",
            "corr_id": corr,
            "ts_ms": nowMs(),
            "phone_fp": phoneFp,
            "trust_id": trustIdField
        ]
        socketBridge.send(json: payload) { _ in }
        emit(["event": "trust.signal_lost", "corr": corr, "reason": reason, "phone_fp": phoneFp])
    }

    private func resetConnectionState() {
        connectInFlight = false
        challengeInFlight = false
        proofSubscribed = false
        currentSignalPresent = false
        stopKeepaliveTimer()
        proofTimeoutItem?.cancel()
        activeCorrId = nil
        activeNonce = nil
        activeChallengeTsMs = nil
        challengeCharacteristic = nil
        proofCharacteristic = nil
        targetPeripheral = nil
    }

    private func forceResetAndRescan(reason: String) {
        emit(["event": "ble.conn.reset", "reason": reason])
        if let p = targetPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        resetConnectionState()
        maybeStartScan()
    }

    private func encodeChallenge(nonce: Data, corrId: String, phoneFp: String, ttlSecs: UInt64) -> Data? {
        guard nonce.count == 16 else { return nil }
        guard let corrData = corrId.data(using: .utf8),
              let fpData = phoneFp.data(using: .utf8),
              corrData.count <= Int(UInt16.max),
              fpData.count <= Int(UInt16.max) else {
            return nil
        }

        var out = Data()
        out.append(nonce)

        var corrLen = UInt16(corrData.count).bigEndian
        out.append(Data(bytes: &corrLen, count: MemoryLayout<UInt16>.size))
        out.append(corrData)

        var fpLen = UInt16(fpData.count).bigEndian
        out.append(Data(bytes: &fpLen, count: MemoryLayout<UInt16>.size))
        out.append(fpData)

        var ttl = ttlSecs.bigEndian
        out.append(Data(bytes: &ttl, count: MemoryLayout<UInt64>.size))
        return out
    }

    private func randomNonce(count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { return nil }
        return Data(bytes)
    }

    private func makeCorrId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<8).map { _ in chars.randomElement(using: &rng)! })
    }

    private func emit(_ obj: [String: Any]) {
        var withPrefix = obj
        withPrefix["role"] = "mac"
        if let data = try? JSONSerialization.data(withJSONObject: withPrefix),
           let line = String(data: data, encoding: .utf8) {
            print("[mac] \(line)")
        }
        onEvent?(withPrefix)
    }

    private func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func parseU64(_ value: Any?) -> UInt64? {
        if let v = value as? UInt64 { return v }
        if let v = value as? Int, v >= 0 { return UInt64(v) }
        if let v = value as? NSNumber {
            let n = v.int64Value
            return n >= 0 ? UInt64(n) : nil
        }
        return nil
    }
}

extension BLETrustCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(["event": "ble.central.state", "state": central.state.rawValue])
        switch central.state {
        case .poweredOn:
            maybeStartScan()
        default:
            sendSignalLost(reason: "central_state_\(central.state.rawValue)")
            if let p = targetPeripheral {
                central.cancelPeripheralConnection(p)
            }
            resetConnectionState()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard !connectInFlight, targetPeripheral == nil else { return }

        emit([
            "event": "ble.scan.found",
            "id": peripheral.identifier.uuidString,
            "rssi": RSSI.intValue,
            "name": peripheral.name ?? ""
        ])

        connectInFlight = true
        targetPeripheral = peripheral
        stopScan()

        emit(["event": "ble.conn.start", "id": peripheral.identifier.uuidString])
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == targetPeripheral?.identifier else { return }
        connectInFlight = false
        emit(["event": "ble.conn.ok", "id": peripheral.identifier.uuidString])
        sendSignalPresent()
        startKeepaliveTimer()

        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == targetPeripheral?.identifier else { return }
        emit([
            "event": "ble.conn.fail",
            "id": peripheral.identifier.uuidString,
            "error": error?.localizedDescription ?? ""
        ])
        sendSignalLost(reason: "connect_failed")
        resetConnectionState()
        maybeStartScan()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == targetPeripheral?.identifier else { return }
        emit([
            "event": "ble.conn.disconnected",
            "id": peripheral.identifier.uuidString,
            "error": error?.localizedDescription ?? ""
        ])
        sendSignalLost(reason: "disconnect")
        resetConnectionState()
        maybeStartScan()
    }
}

extension BLETrustCentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            emit(["event": "ble.gatt.services.error", "error": error.localizedDescription])
            return
        }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.challengeUUID, Self.proofUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            emit(["event": "ble.gatt.chars.error", "error": error.localizedDescription])
            return
        }

        guard let chars = service.characteristics else { return }
        for ch in chars {
            if ch.uuid == Self.challengeUUID { challengeCharacteristic = ch }
            if ch.uuid == Self.proofUUID { proofCharacteristic = ch }
        }

        guard challengeCharacteristic != nil, let proofCharacteristic else {
            emit(["event": "ble.gatt.chars.missing"])
            return
        }

        emit(["event": "ble.gatt.ready", "chars": "challenge,proof"])
        peripheral.setNotifyValue(true, for: proofCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            emit(["event": "ble.gatt.notify.error", "error": error.localizedDescription])
            return
        }
        guard characteristic.uuid == Self.proofUUID else { return }
        proofSubscribed = characteristic.isNotifying
        emit(["event": "ble.gatt.notify", "enabled": characteristic.isNotifying])
        if characteristic.isNotifying {
            beginHandshakeIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.challengeUUID else { return }
        if let error {
            emit(["event": "trust.challenge.write_error", "error": error.localizedDescription])
        } else {
            emit(["event": "trust.challenge.written"])
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.proofUUID else { return }
        if let error {
            emit(["event": "trust.proof.read_error", "error": error.localizedDescription])
            return
        }
        guard let proof = characteristic.value, proof.count == 32 else {
            emit(["event": "trust.proof.invalid", "size": characteristic.value?.count ?? 0])
            return
        }
        let corr = activeCorrId ?? ""
        emit(["event": "trust.proof.recv", "corr": corr, "hmac8": String(proof.hex.prefix(8)), "phone_fp": phoneFp])
        forwardProof(proof)
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
