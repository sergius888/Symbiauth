import Foundation
import Network
import os.log

/// Thread-safe, strict corr_id → NWConnection router with hygiene (unbind + GC)
/// Routes agent responses to the exact iOS connection that sent the request
final class CorrRouter {
    private struct Route {
        weak var conn: NWConnection?
        var lastSeen: TimeInterval
    }
    
    private var routes: [String: Route] = [:]
    private weak var lastConn: NWConnection?
    private let queue = DispatchQueue(label: "com.armadillo.tls.router", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.armadillo.tls", category: "CorrRouter")
    
    /// Bind a corr_id to a specific NWConnection for routing
    func bind(_ corrId: String, to conn: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.routes[corrId] = Route(conn: conn, lastSeen: now)
            self.lastConn = conn
            self.logger.info("🔗 bind_route corr_id=\(corrId) conn=\(String(describing: ObjectIdentifier(conn)))")
        }
    }
    
    /// Retrieve the NWConnection bound to a corr_id (and refresh lastSeen)
    func route(_ corrId: String) -> NWConnection? {
        queue.sync { [weak self] in
            guard let self = self else { return nil }
            guard var r = self.routes[corrId], let c = r.conn else {
                return nil
            }
            r.lastSeen = CFAbsoluteTimeGetCurrent()
            self.routes[corrId] = r
            self.lastConn = c
            return c
        }
    }

    /// Fallback: return most recently seen connection (if still alive)
    func fallbackConn() -> NWConnection? {
        return queue.sync { [weak self] in
            guard let self = self else { return nil }
            return self.lastConn
        }
    }
    
    /// Refresh lastSeen without returning the conn (optional, e.g., before route_out)
    func touch(_ corrId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard var r = self.routes[corrId] else { return }
            r.lastSeen = CFAbsoluteTimeGetCurrent()
            self.routes[corrId] = r
        }
    }
    
    /// Drop all routes for a given connection (call on disconnect)
    func drop(_ conn: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let id = ObjectIdentifier(conn)
            let before = self.routes.count
            self.routes = self.routes.filter { $0.value.conn != nil && ObjectIdentifier($0.value.conn!) != id }
            let removed = before - self.routes.count
            if removed > 0 {
                self.logger.info("🗑️ drop_routes_for_conn conn=\(String(describing: id)) removed=\(removed)")
            }
            if let last = self.lastConn, ObjectIdentifier(last) == id {
                self.lastConn = nil
            }
        }
    }
    
    /// Garbage-collect stale routes (e.g., idle >120s or nil conn)
    func gc(olderThan seconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self = self else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let before = self.routes.count
        self.routes = self.routes.filter { _, route in
            guard route.conn != nil else { return false }
            return (now - route.lastSeen) <= seconds
        }
        let removed = before - self.routes.count
        if removed > 0 {
            self.logger.info("🧹 gc_drop removed=\(removed)")
        }
        }
    }
    
    /// Get current route count (for diagnostics)
    func routeCount() -> Int {
        return queue.sync { [weak self] in
            self?.routes.count ?? 0
        }
    }
}
