import Cocoa
import Combine
import CryptoKit
import Network
import os.log
import CoreImage
import PDFKit
import Security
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let logger = Logger(subsystem: "com.armadillo.tls", category: "AppDelegate")
    
    var certificateManager: CertificateManager!
    var bonjourService: BonjourService!
    var tlsServer: TLSServer!
    var enrollmentServer: EnrollmentServer!
    
    var deviceIdentity: SecIdentity?
    var deviceFingerprint: String?
    
    // QR Code support
    var pairingSessionManager: PairingSessionManager!
    var qrDisplayWindow: QRDisplayWindow?
    var preferencesWindowController: PreferencesWindowController?
    var chamberWindowController: SecretChamberWindowController?
    var sharedPreferencesViewModel: PreferencesViewModel?
    var lastAutoOpenedChamberTrustId: String?
    var manuallyDismissedChamberTrustId: String?
    var chamberDismissedByUser = false
    
    // Menu bar support
    var statusItem: NSStatusItem?
    var trustMenuRefreshTimer: Timer?
    var openMenuRefreshTimer: Timer?
    var selectedTrustModeOverride: String?
    let launcherListRefreshInterval: TimeInterval = 5.0

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("🛡️ Armadillo TLS Terminator starting up")
        NSLog("🛡️ NSLOG: Armadillo TLS Terminator starting up")
        logger.info("Armadillo TLS Terminator starting up")
        
        // Force flush logs
        fflush(stdout)
        fflush(stderr)
        
        // Hide any main window and run as menu bar app only
        NSApp.setActivationPolicy(.accessory)
        installApplicationMainMenu()
        
        do {
            print("🔧 Initializing services...")
            try initializeServices()
            ensureNativeMessagingManifestInstalled()
            print("📱 Setting up menu bar...")
            setupMenuBar()
            _ = sharedViewModel()
            handleChamberLifecycleForCurrentTrustState()
            print("✅ All services initialized successfully")
            logger.info("All services initialized successfully")
        } catch {
            print("❌ Failed to initialize services: \(error.localizedDescription)")
            logger.error("Failed to initialize services: \(error.localizedDescription)")
            NSApplication.shared.terminate(nil)
        }
        
        // Refresh menu when allowed clients change
        NotificationCenter.default.addObserver(self, selector: #selector(onAllowedClientsChanged), name: TLSServer.allowedClientsChangedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onTrustStateChanged), name: TLSServer.trustStateChangedNotification, object: nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        logger.info("Armadillo TLS Terminator shutting down")
        trustMenuRefreshTimer?.invalidate()
        trustMenuRefreshTimer = nil
        openMenuRefreshTimer?.invalidate()
        openMenuRefreshTimer = nil
        cleanup()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running as menu bar app
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    // MARK: - Service Initialization
    
    private func initializeServices() throws {
        // Initialize certificate manager
        certificateManager = CertificateManager()
        
        // Initialize pairing session manager
        pairingSessionManager = PairingSessionManager()
        
        // 1) Build server identity once
        let (serverIdentity, fingerprint) = try certificateManager.getOrCreateIdentity()
        deviceIdentity = serverIdentity
        deviceFingerprint = fingerprint
        
        print("🔑 Device fingerprint: \(fingerprint)")
        logger.info("MAIN/QR leaf fingerprint (sha256) = \(fingerprint)")
        
        // Initialize Bonjour service (but don't publish yet)
        bonjourService = BonjourService(fingerprint: fingerprint)
        
        // 2) Start main TLS with the same identity
        tlsServer = try TLSServer(identity: serverIdentity, fingerprint: fingerprint)
        
        // Set up callback to publish Bonjour when TLS server is ready
        tlsServer.onReady = { [weak self] port in
            guard let self = self else { return }
            do {
                try self.bonjourService.publish(port: port)
                print("🌐 TLS server listening on port \(port)")
                self.logger.info("TLS server listening on port \(port)")
            } catch {
                print("⚠️ Failed to publish Bonjour service: \(error)")
                self.logger.error("Failed to publish Bonjour service: \(error.localizedDescription)")
            }
        }
        
        // Start TLS server (Bonjour will be published via callback)
        try tlsServer.start()
        
        // 3) Start ENROLL with the **same** identity
        enrollmentServer = EnrollmentServer(
            serverIdentity: serverIdentity,
            certificateManager: certificateManager,
            port: 8444
        )
        try enrollmentServer.start()
    }
    
    private func cleanup() {
        bonjourService?.stop()
        tlsServer?.stop()
        enrollmentServer?.stop()
    }

    private func installApplicationMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = "SymbiAuth"
        appMenu.addItem(
            withTitle: "Preferences…",
            action: #selector(openPreferencesWindow),
            keyEquivalent: ","
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - 7d Step 1 Preferences Shell
