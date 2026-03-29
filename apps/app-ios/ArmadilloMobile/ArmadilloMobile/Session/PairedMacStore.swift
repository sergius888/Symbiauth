// STATUS: ACTIVE
// PURPOSE: persists list of paired Macs and tracks which one is "Active" for BLE advertising

import Foundation

// MARK: - Model

struct PairedMac: Codable, Identifiable {
    var id: String { macId }
    let macId: String         // agent_fp (sha256:hex) — stable unique ID
    var label: String         // payload.name
    var fpSuffix: String      // last 12 chars of macId (passed as macFpSuffix to BLEAdvertiser)
    var wrapPubB64: String?   // Mac's P-256 wrap public key — nil until pairing.ack fills it in
    let pairedAt: Date        // set once at QR scan time, never overwritten
}

// MARK: - Store

/// Manages the list of paired Macs and the active Mac selection.
/// Storage: UserDefaults only (wrapPubB64 is a public key, not a secret).
final class PairedMacStore {

    private let macsKey    = "paired_macs_v1"
    private let activeKey  = "active_mac_id"
    private let legacyKey  = "wrap_pub_mac_b64"
    private let defaults   = UserDefaults.standard

    init() {
        migrateLegacyIfNeeded()
    }

    // MARK: CRUD

    func loadAll() -> [PairedMac] {
        guard let data = defaults.data(forKey: macsKey),
              let dict = try? JSONDecoder().decode([String: PairedMac].self, from: data) else {
            return []
        }
        return Array(dict.values).sorted { $0.pairedAt < $1.pairedAt }
    }

    /// Upsert by macId. Preserves original `pairedAt` if record already exists.
    func save(_ mac: PairedMac) {
        var dict = loadDict()
        if let existing = dict[mac.macId] {
            // Keep original pairedAt; update mutable fields only
            var updated = mac
            // Preserve the original pairedAt
            _ = existing.pairedAt  // silence unused warning; struct is value-type, existing is captured below
            let original = PairedMac(
                macId: mac.macId,
                label: mac.label,
                fpSuffix: mac.fpSuffix,
                wrapPubB64: mac.wrapPubB64,
                pairedAt: existing.pairedAt  // ← stable
            )
            updated = original
            dict[mac.macId] = updated
        } else {
            dict[mac.macId] = mac
        }
        persist(dict)
    }

    func remove(macId: String) {
        var dict = loadDict()
        dict.removeValue(forKey: macId)
        persist(dict)
        // Clear active if it was this mac
        if activeMacId() == macId {
            defaults.removeObject(forKey: activeKey)
        }
    }

    /// Rename a paired Mac label while preserving identity and pairing metadata.
    func rename(macId: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var dict = loadDict()
        guard var mac = dict[macId] else { return }
        mac = PairedMac(
            macId: mac.macId,
            label: trimmed,
            fpSuffix: mac.fpSuffix,
            wrapPubB64: mac.wrapPubB64,
            pairedAt: mac.pairedAt
        )
        dict[macId] = mac
        persist(dict)
    }

    // MARK: Active selection

    func activeMacId() -> String? {
        defaults.string(forKey: activeKey)
    }

    func setActiveMacId(_ id: String) {
        defaults.set(id, forKey: activeKey)
    }

    func activeMac() -> PairedMac? {
        guard let id = activeMacId() else { return nil }
        return loadDict()[id]
    }

    /// Fill in wrapPubB64 for a specific macId (called on pairing.ack).
    /// Safe against races: keyed by macId, not by "active mac".
    func setWrapPub(_ wrapPubB64: String, forMacId macId: String) {
        var dict = loadDict()
        guard var mac = dict[macId] else { return }
        mac = PairedMac(
            macId: mac.macId,
            label: mac.label,
            fpSuffix: mac.fpSuffix,
            wrapPubB64: wrapPubB64,
            pairedAt: mac.pairedAt
        )
        dict[macId] = mac
        persist(dict)
    }

    // MARK: Private helpers

    private func loadDict() -> [String: PairedMac] {
        guard let data = defaults.data(forKey: macsKey),
              let dict = try? JSONDecoder().decode([String: PairedMac].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func persist(_ dict: [String: PairedMac]) {
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: macsKey)
        }
    }

    /// One-time migration: if old single-key exists and no list exists yet, create a legacy record.
    private func migrateLegacyIfNeeded() {
        guard let legacyWrapPub = defaults.string(forKey: legacyKey),
              !legacyWrapPub.isEmpty,
              loadDict().isEmpty else { return }

        let legacyId = "legacy-\(UUID().uuidString)"
        let legacy = PairedMac(
            macId: legacyId,
            label: "Legacy Mac",
            fpSuffix: "legacy",
            wrapPubB64: legacyWrapPub,
            pairedAt: Date()
        )
        var dict = [String: PairedMac]()
        dict[legacyId] = legacy
        persist(dict)
        setActiveMacId(legacyId)
        defaults.removeObject(forKey: legacyKey)
        print("[ios] paired_macs: migrated legacy wrap_pub_mac_b64 → legacy-mac id=\(legacyId)")
    }
}
