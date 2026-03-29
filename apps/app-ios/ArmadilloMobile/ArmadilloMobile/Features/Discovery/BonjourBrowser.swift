import Foundation
import Network

class BonjourBrowser: NSObject, ObservableObject {
    private var browser: NWBrowser?
    private var resolver: NWConnection? // keep strong ref (single-use paths)
    private var didComplete = false // call completion once
    private var discoveryCompletion: ((Result<(host: String, port: UInt16), BonjourError>) -> Void)?
    
    // Multi-candidate discovery state
    private var multiCompletion: ((([(host: String, port: UInt16, name: String)]) -> Void))?
    private var collectedCandidates: [(host: String, port: UInt16, name: String)] = []
    private var seenServiceIds = Set<String>()
    private var activeResolvers: [ObjectIdentifier: NWConnection] = [:]
    private var multiTimeoutWork: DispatchWorkItem?
    
    /// Discover a specific service by type (Env.bonjourServiceType)
    func discover(serviceName: String, completion: @escaping (Result<(host: String, port: UInt16), BonjourError>) -> Void) {
        ArmadilloLogger.discovery.info("Starting discovery for service: \(serviceName)")
        
        self.discoveryCompletion = completion
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browserDescriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: Env.bonjourServiceType,
            domain: nil
        )
        
        browser = NWBrowser(for: browserDescriptor, using: parameters)
        
        browser?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ArmadilloLogger.discovery.info("Bonjour browser ready")
            case .failed(let error):
                ArmadilloLogger.discovery.error("Bonjour browser failed: \(error.localizedDescription)")
                self?.completeDiscovery(with: .failure(.browserFailed(error)))
            case .cancelled:
                ArmadilloLogger.discovery.info("Bonjour browser cancelled") // informational only
            default:
                break
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleBrowseResults(results: results, targetService: serviceName)
        }
        
        browser?.start(queue: .main)
        
        // Set timeout for discovery
        DispatchQueue.main.asyncAfter(deadline: .now() + Env.connectTimeout) { [weak self] in
            if self?.discoveryCompletion != nil {
                self?.completeDiscovery(with: .failure(.timeout))
            }
        }
    }
    
    /// Discover by instance name (e.g., "SwiftShield-1234") using known service type
    func discoverInstance(instanceName: String, completion: @escaping (Result<(host: String, port: UInt16), BonjourError>) -> Void) {
        ArmadilloLogger.discovery.info("Starting discovery for instance: \(instanceName)")
        
        self.discoveryCompletion = completion
        didComplete = false
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browserDescriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: Env.bonjourServiceType,
            domain: nil
        )
        
        browser = NWBrowser(for: browserDescriptor, using: parameters)
        
        browser?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ArmadilloLogger.discovery.info("Bonjour browser ready")
            case .failed(let error):
                ArmadilloLogger.discovery.error("Bonjour browser failed: \(error.localizedDescription)")
                self?.completeDiscovery(with: .failure(.browserFailed(error)))
            case .cancelled:
                ArmadilloLogger.discovery.info("Bonjour browser cancelled")
            default:
                break
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self, !self.didComplete else { return }
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint, name == instanceName {
                    ArmadilloLogger.discovery.info("Found target instance: \(name)")
                    self.resolveService(result: result)
                    return
                }
            }
        }
        
        browser?.start(queue: .main)
        
        // Timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Env.connectTimeout) { [weak self] in
            if self?.discoveryCompletion != nil {
                self?.completeDiscovery(with: .failure(.timeout))
            }
        }
    }
    
    /// Discover and collect multiple services for a fixed timeout. Returns all resolved candidates.
    func discoverAll(timeout: TimeInterval, completion: @escaping ([(host: String, port: UInt16, name: String)]) -> Void) {
        ArmadilloLogger.discovery.info("Starting multi-discovery for any armadillo service (\(timeout)s)")
        
        // Reset multi state
        collectedCandidates.removeAll()
        seenServiceIds.removeAll()
        activeResolvers.removeAll()
        multiCompletion = completion
        didComplete = false
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browserDescriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: Env.bonjourServiceType,
            domain: nil
        )
        
        browser?.cancel()
        browser = NWBrowser(for: browserDescriptor, using: parameters)
        
        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ArmadilloLogger.discovery.info("Bonjour browser ready (multi)")
            case .failed(let error):
                ArmadilloLogger.discovery.error("Bonjour browser failed (multi): \(error.localizedDescription)")
            case .cancelled:
                ArmadilloLogger.discovery.info("Bonjour browser cancelled (multi)")
            default:
                break
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            for result in results {
                if case .service(let name, let type, let domain, _) = result.endpoint {
                    let serviceId = "\(name)|\(type)|\(domain)"
                    if !self.seenServiceIds.contains(serviceId) {
                        self.seenServiceIds.insert(serviceId)
                        ArmadilloLogger.discovery.debug("Multi: queue resolve for \(name) type: \(type)")
                        self.resolveToCandidate(result: result, instanceName: name)
                    }
                }
            }
        }
        
        browser?.start(queue: .main)
        
        // Complete after timeout with whatever we collected
        multiTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let completion = self.multiCompletion else { return }
            self.browser?.cancel()
            self.browser = nil
            // Cancel all active resolvers
            for (_, conn) in self.activeResolvers { conn.cancel() }
            self.activeResolvers.removeAll()
            let result = self.collectedCandidates
            self.collectedCandidates.removeAll()
            self.seenServiceIds.removeAll()
            self.multiCompletion = nil
            ArmadilloLogger.discovery.info("Multi-discovery completed with \(result.count) candidates")
            completion(result)
        }
        multiTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }
    
    private func resolveToCandidate(result: NWBrowser.Result, instanceName: String) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        
        let connection = NWConnection(to: result.endpoint, using: params)
        let key = ObjectIdentifier(connection)
        activeResolvers[key] = connection
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let resolved = connection.currentPath?.remoteEndpoint ?? connection.endpoint
                if case let .hostPort(host, port) = resolved {
                    let hostString: String
                    switch host {
                    case .name(let name, _): hostString = name
                    case .ipv4(let ipv4): hostString = ipv4.debugDescription
                    case .ipv6(let ipv6): hostString = ipv6.debugDescription
                    @unknown default: hostString = "unknown"
                    }
                    ArmadilloLogger.discovery.info("Resolved candidate \(instanceName) -> \(hostString):\(port.rawValue)")
                    self.collectedCandidates.append((host: hostString, port: port.rawValue, name: instanceName))
                } else {
                    ArmadilloLogger.discovery.warning("Resolution ready but no hostPort for \(instanceName)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    connection.cancel()
                    self.activeResolvers.removeValue(forKey: key)
                }
            case .failed:
                DispatchQueue.main.async {
                    connection.cancel()
                    self.activeResolvers.removeValue(forKey: key)
                }
            default:
                break
            }
        }
        
        connection.start(queue: .main)
    }
    
    private func handleBrowseResults(results: Set<NWBrowser.Result>, targetService: String) {
        for result in results {
            switch result.endpoint {
            case .service(let name, let type, let domain, _):
                ArmadilloLogger.discovery.debug("Found service: \(name) type: \(type) domain: \(domain)")
                
                if name == targetService {
                    ArmadilloLogger.discovery.info("Found target service: \(name)")
                    resolveService(result: result)
                    return
                }
            default:
                continue
            }
        }
    }
    
    private func resolveService(result: NWBrowser.Result) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        
        let connection = NWConnection(to: result.endpoint, using: params)
        self.resolver = connection // keep strong ref
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.didComplete else { return }
            switch state {
            case .ready:
                // Try currentPath first, then fall back to endpoint
                let resolved = connection.currentPath?.remoteEndpoint ?? connection.endpoint
                if case let .hostPort(host, port) = resolved {
                    self.didComplete = true
                    self.extractEndpointInfo(from: resolved)
                    // Cancel a tick later to avoid races
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { connection.cancel() }
                } else {
                    ArmadilloLogger.discovery.warning("Resolution ready but no hostPort; falling back to QR")
                    self.didComplete = true
                    self.completeDiscovery(with: .failure(.resolutionFailed))
                    DispatchQueue.main.async { connection.cancel() }
                }
            case .failed(let error):
                ArmadilloLogger.discovery.error("Service resolution failed: \(error.localizedDescription)")
                self.didComplete = true
                self.completeDiscovery(with: .failure(.resolutionFailed))
                DispatchQueue.main.async { connection.cancel() }
            default:
                break
            }
        }
        
        connection.start(queue: .main)
    }
    
    private func extractEndpointInfo(from endpoint: NWEndpoint) {
        switch endpoint {
        case .hostPort(let host, let port):
            let hostString: String
            switch host {
            case .name(let name, _):
                hostString = name
            case .ipv4(let ipv4):
                hostString = ipv4.debugDescription
            case .ipv6(let ipv6):
                hostString = ipv6.debugDescription
            @unknown default:
                hostString = "unknown"
            }
            
            ArmadilloLogger.discovery.info("Resolved service to \(hostString):\(port.rawValue)")
            completeDiscovery(with: .success((host: hostString, port: port.rawValue)))
            
        default:
            completeDiscovery(with: .failure(.resolutionFailed))
        }
    }
    
    private func completeDiscovery(with result: Result<(host: String, port: UInt16), BonjourError>) {
        guard let completion = discoveryCompletion else { return }
        
        discoveryCompletion = nil
        didComplete = true
        browser?.cancel()
        browser = nil
        resolver?.cancel()
        resolver = nil
        
        completion(result)
    }
    
    func stop() {
        browser?.cancel()
        browser = nil
        resolver?.cancel()
        resolver = nil
        discoveryCompletion = nil
        didComplete = true
        
        // Reset multi mode too
        multiCompletion = nil
        collectedCandidates.removeAll()
        seenServiceIds.removeAll()
        for (_, conn) in activeResolvers { conn.cancel() }
        activeResolvers.removeAll()
        multiTimeoutWork?.cancel()
        multiTimeoutWork = nil
    }
}

enum BonjourError: LocalizedError {
    case browserFailed(Error)
    case timeout
    case resolutionFailed
    
    var errorDescription: String? {
        switch self {
        case .browserFailed(let error):
            return "Bonjour browser failed: \(error.localizedDescription)"
        case .timeout:
            return "Service discovery timed out"
        case .resolutionFailed:
            return "Failed to resolve service address"
        }
    }
}