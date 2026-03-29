import Foundation

enum ChamberCategory: String, CaseIterable {
    case all
    case secrets
    case notes
    case documents
    case favorites
    case shell

    var title: String {
        switch self {
        case .all: return "All"
        case .secrets: return "Secrets"
        case .notes: return "Notes"
        case .documents: return "Documents"
        case .favorites: return "Favorites"
        case .shell: return "Trusted Shell"
        }
    }
}

enum ChamberStoredKind: String, Codable, CaseIterable {
    case note
    case document
    case secret

    var title: String {
        switch self {
        case .secret: return "Secret"
        case .note: return "Note"
        case .document: return "Document"
        }
    }
}

struct ChamberStoredItem: Identifiable, Codable {
    var id: UUID = UUID()
    var kind: ChamberStoredKind
    var title: String
    var note: String
    var tags: [String]
    var favorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
    var body: String?
    var format: String?
    var fileName: String?
    var mimeType: String?
    var fileData: Data?
    var fileSize: Int?
}

struct ChamberDraft {
    var kind: ChamberStoredKind = .secret
    var title: String = ""
    var note: String = ""
    var tagsText: String = ""
    var secretName: String = ""
    var secretValue: String = ""
    var secretType: String = "custom"
    var secretAvailableInShell: Bool = false
    var body: String = ""
    var noteFormat: String = "plain_text"
    var fileName: String = ""
    var mimeType: String = ""
    var fileData: Data?
    var editingStoredItemId: UUID?
}

struct ChamberItem: Identifiable {
    enum Kind {
        case secret
        case note
        case document
    }

    let id: String
    let kind: Kind
    let title: String
    let note: String
    let tags: [String]
    let favorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let lastOpenedAt: Date?
    let secretName: String?
    let secretType: String?
    let secretAvailableInShell: Bool
    let secretAvailable: Bool
    let secretStatus: String?
    let secretUsedBy: [String]
    let textContent: String?
    let textFormat: String?
    let fileName: String?
    let mimeType: String?
    let fileData: Data?
    let fileSize: Int?

    var category: ChamberCategory {
        switch kind {
        case .secret: return .secrets
        case .note: return .notes
        case .document: return .documents
        }
    }
}

struct SecretPresentationConfiguration: Codable {
    var title: String? = nil
    var type: String = "custom"
    var availableInShell: Bool = false
}

struct ChamberPresentationMetadata: Codable {
    var favoriteSecretNames: Set<String> = []
    var recentSecretAccess: [String: Date] = [:]
    var secretTags: [String: [String]] = [:]
    var secretConfigurations: [String: SecretPresentationConfiguration] = [:]
}
