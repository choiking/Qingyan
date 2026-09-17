import Foundation

enum LocalPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalInput", isDirectory: true)
    }
    static var ipc: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    static var rime: URL { root.appendingPathComponent("Rime", isDirectory: true) }
    static func prepare() throws {
        for url in [root, ipc, rime] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
    static func file(_ id: UUID, _ suffix: String) -> URL { ipc.appendingPathComponent("\(id.uuidString).\(suffix).json") }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func remove(_ id: UUID) {
        for suffix in ["request", "reply", "command", "hold"] { try? FileManager.default.removeItem(at: file(id, suffix)) }
    }
    static func cleanStaleSessions() {
        let files = (try? FileManager.default.contentsOfDirectory(at: ipc, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > 600 { try? FileManager.default.removeItem(at: file) }
        }
    }
}

struct Settings: Codable {
    var language = "auto"
    var fontSize: Double = 18
    var shiftToggle = true
    var modelPath = ""
    var voiceVocabulary = "轻言\nQingyan"
    var correctionEnabled = false
    var voiceShortcut = VoiceShortcut.defaultShortcut
    init() {}
    private enum CodingKeys: String, CodingKey { case language, fontSize, shiftToggle, modelPath, voiceShortcut, voiceVocabulary, correctionEnabled }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 18
        shiftToggle = try values.decodeIfPresent(Bool.self, forKey: .shiftToggle) ?? true
        modelPath = try values.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
        voiceVocabulary = try values.decodeIfPresent(String.self, forKey: .voiceVocabulary) ?? "轻言\nQingyan"
        correctionEnabled = try values.decodeIfPresent(Bool.self, forKey: .correctionEnabled) ?? false
        // Old settings have no shortcut. A damaged shortcut must not reset the user's other preferences.
        if let shortcut = try? values.decode(VoiceShortcut.self, forKey: .voiceShortcut), shortcut.validationError == nil {
            voiceShortcut = shortcut
        }
    }
    static var url: URL { LocalPaths.root.appendingPathComponent("settings.json") }
    static func load() -> Settings { LocalPaths.read(Self.self, from: url) ?? Settings() }
    func save() throws { try LocalPaths.write(self, to: Self.url) }
}
struct VoiceRequest: Codable {
    let id: UUID
    let language: String
    let created: Date
    var heldShortcut: VoiceShortcut? = nil
    enum CaptureAdmission { case allowed, released, cancelled, disconnected }
    func captureAdmission(command: String?, lease: VoiceHoldLease?, now: Date) -> CaptureAdmission {
        if command == "cancel" { return .cancelled }
        if command == "stop" { return .released }
        guard heldShortcut != nil else { return .allowed }
        guard let lease, lease.id == id, lease.isFresh(at: now) else { return .disconnected }
        return .allowed
    }
}
struct VoiceReply: Codable, Equatable {
    let phase: String
    var text = ""
    var detail = ""
    var originalText: String? = nil
}
struct VoiceCommand: Codable { let action: String }

// This is a liveness signal from the IMK event owner, not a physical-key query.
// Stop/cancel commands are separate so a heartbeat can never overwrite a release.
struct VoiceHoldLease: Codable {
    let id: UUID
    let renewedAt: Date
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(renewedAt)
        return age >= -1 && age < 3
    }
}

// A Shift tap toggles mode; using Shift in a chord must never toggle it.
struct ShiftTapTracker {
    private var downAt: TimeInterval?
    private var usedInChord = false
    mutating func keyDown() { if downAt != nil { usedInChord = true } }
    mutating func update(shift: Bool, otherModifier: Bool, time: TimeInterval) -> Bool {
        if shift {
            if downAt == nil { downAt = time; usedInChord = otherModifier }
            if otherModifier { usedInChord = true }
            return false
        }
        defer { reset() }
        guard let start = downAt else { return false }
        return !usedInChord && !otherModifier && time - start < 0.6
    }
    mutating func reset() { downAt = nil; usedInChord = false }
}

// Replies may only be committed to the same input session / focus generation.
struct VoiceCommitGuard {
    var session: UUID?
    var generation = 0
    mutating func begin(_ id: UUID) { session = id }
    mutating func invalidate() { session = nil; generation += 1 }
    func accepts(_ id: UUID, generation expected: Int) -> Bool { session == id && generation == expected }
}
