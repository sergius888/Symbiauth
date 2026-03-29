import Foundation
import CoreBluetooth
import CryptoKit
import os.log

final class BLEScanner: NSObject, CBCentralManagerDelegate {
    private let logger = Logger(subsystem: "com.armadillo.tls", category: "BLEScanner")
    private var cm: CBCentralManager!
    private let kBle: Data
    private let macFpSuffix: String
    private var expected: [CBUUID] = []
    private var presenceUntil: Date = .distantPast
    private let onEvent: (([String: Any]) -> Void)?
    private let rssiThreshold: Int
    private let logLevel: String
    private var present: Bool = false
    private var lastEmit: Date = .distantPast
    private var tickTimer: Timer?
    private var metricTimer: Timer?
    private var metricWindowStart: Date = Date()
    private var metricPresentAccum: TimeInterval = 0
    private var lastTickTime: Date = Date()

    init(kBle: Data, macFpSuffix: String, logLevel: String = "info", onEvent: (([String: Any]) -> Void)? = nil) {
        self.kBle = kBle
        self.macFpSuffix = String(macFpSuffix.suffix(12))
        self.onEvent = onEvent
        self.logLevel = logLevel
        if let s = ProcessInfo.processInfo.environment["ARM_BLE_RSSI_MIN"], let v = Int(s) {
            self.rssiThreshold = v
        } else {
            self.rssiThreshold = -70
        }
        super.init()
        self.cm = CBCentralManager(delegate: self, queue: .main)
        // Timers: presence tick (1s) and metric (60s)
        self.tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        self.metricTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.emitMetric()
        }
        self.metricWindowStart = Date()
        self.lastTickTime = Date()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            logger.info("BLE central not powered on")
            return
        }
        recomputeExpectedUUIDs()
        cm.scanForPeripherals(withServices: expected, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        emit(["event":"ble.scan.update","epochs":3])
    }

    private func recomputeExpectedUUIDs() {
        expected.removeAll()
        let now = Date().timeIntervalSince1970
        let base = UInt64((now/60.0).rounded(.down))
        for off in -1...1 {
            let epoch: UInt64
            if off < 0 {
                epoch = base &- UInt64(-off)
            } else {
                epoch = base &+ UInt64(off)
            }
            expected.append(deriveEpochUUID(epoch: epoch))
        }
        // Emit expected UUIDs for diagnostics
        let ids = expected.map { $0.uuidString }
        emit(["event":"ble.expected","uuids": ids])
    }

    private func deriveEpochUUID(epoch: UInt64) -> CBUUID {
        var msg = Data()
        msg.append("blev1".data(using: .utf8)!)
        msg.append(Data(macFpSuffix.utf8))
        var e = epoch.bigEndian
        msg.append(Data(bytes: &e, count: MemoryLayout<UInt64>.size))
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: kBle))
        return CBUUID(data: Data(mac.prefix(16)))
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        guard let svcs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] else { return }
        if svcs.contains(where: expected.contains) {
            // Emit sighting only at debug log level
            if logLevel == "debug" {
                emit(["event":"ble.seen","rssi": RSSI.intValue])
            }
            if RSSI.intValue >= rssiThreshold {
                let ttl = Self.readPresenceTTL()
                presenceUntil = Date().addingTimeInterval(ttl)
                if !present {
                    present = true
                    lastEmit = Date()
                    emit(["event":"ble.presence","state":"enter","rssi": RSSI.intValue])
                }
            }
        }
    }

    var isPresent: Bool { Date() < presenceUntil }

    private func emit(_ obj: [String: Any]) {
        if let onEvent = onEvent {
            onEvent(obj)
        } else {
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
        }
    }

    private static func readPresenceTTL() -> TimeInterval {
        if let s = ProcessInfo.processInfo.environment["ARM_BLE_PRESENCE_TTL"], let v = Int(s) {
            let clamped = max(1, min(30, v))
            return TimeInterval(clamped)
        }
        return 5.0
    }

    private func tick() {
        let now = Date()
        // Accumulate metric time since last tick
        let dt = now.timeIntervalSince(lastTickTime)
        if present { metricPresentAccum += dt }
        lastTickTime = now
        // Presence exit
        if present && now >= presenceUntil {
            present = false
            emit(["event":"ble.presence","state":"exit"])
            return
        }
        // Presence keepalive
        if present {
            let ttl = Self.readPresenceTTL()
            let minGap = max(3.0, ttl / 2.0)
            if now.timeIntervalSince(lastEmit) >= minGap {
                lastEmit = now
                emit(["event":"ble.presence","state":"keepalive"])
            }
        }
    }

    private func emitMetric() {
        let window = 60.0
        emit(["metric":"ble_presence_ratio","window_s":Int(window),"present_s":Int(metricPresentAccum.rounded())])
        metricPresentAccum = 0
        metricWindowStart = Date()
    }
}


