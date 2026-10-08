import CryptoKit
import Foundation
import SwiftData

@Model final class PracticeRecord {
    @Attribute(.unique) var id: UUID
    var owner: String
    var sessionID: UUID
    var idempotencyKey: UUID
    var startedAt: Date
    var endedAt: Date?
    var updatedAt: Date
    var goal: String
    var level: String
    var topic: String?
    var durationMinutes: Int
    var status: String
    var issue: String?
    var reportData: Data?
    var manifestData: Data?

    init(id: UUID, owner: String, sessionID: UUID, key: UUID, preferences: SessionPreferences) {
        self.id = id; self.owner = owner; self.sessionID = sessionID; self.idempotencyKey = key
        self.startedAt = Date(); self.updatedAt = Date()
        self.goal = preferences.speakingGoal; self.level = preferences.level
        self.topic = preferences.preferredTopic; self.durationMinutes = preferences.sessionDurationMinutes
        self.status = "active"
    }
}

@Model final class SavedPart {
    var id: String
    var practiceID: UUID
    var speaker: String
    var text: String
    var playback: String
    var offsetMilliseconds: Int

    init(id: String, practiceID: UUID, speaker: String, text: String, playback: String, offsetMilliseconds: Int) {
        self.id = id; self.practiceID = practiceID; self.speaker = speaker; self.text = text
        self.playback = playback; self.offsetMilliseconds = offsetMilliseconds
    }
}

@Model final class JournalItem {
    var id: String
    var practiceID: UUID
    var kind: String
    var payload: Data?
    var fileName: String?
    var contentType: String
    var sha256: String
    var receipt: String
    var issue: String?

    init(id: String, practiceID: UUID, kind: String, payload: Data?, fileName: String?, contentType: String, sha256: String) {
        self.id = id; self.practiceID = practiceID; self.kind = kind; self.payload = payload
        self.fileName = fileName; self.contentType = contentType; self.sha256 = sha256
        self.receipt = "pending"
    }
}

@MainActor final class PracticeStore: ObservableObject {
    @Published private(set) var practices: [PracticeRecord] = []
    @Published private(set) var parts: [SavedPart] = []
    @Published private(set) var journal: [JournalItem] = []
    @Published private(set) var accountID: String

    private let container: ModelContainer
    private let context: ModelContext
    private let files: URL
    private let manager = FileManager.default

    init(directory: URL? = nil, accountID: String = "local") throws {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Practices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = root.appending(path: "Audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        self.files = files
        self.accountID = accountID
        for url in [root, files] {
            try? (url as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        let configuration = ModelConfiguration(url: root.appending(path: "Practices.store"))
        container = try ModelContainer(for: PracticeRecord.self, SavedPart.self, JournalItem.self, configurations: configuration)
        context = ModelContext(container)
        for name in ["Practices.store", "Practices.store-wal", "Practices.store-shm"] {
            let url = root.appending(path: name)
            guard manager.fileExists(atPath: url.path) else { continue }
            try? (url as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
            try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        refresh()
        reconcile()
    }

    func switchAccount(to id: String) {
        accountID = id
        refresh()
    }

    func refresh() {
        let owner = accountID
        let practiceQuery = FetchDescriptor<PracticeRecord>(predicate: #Predicate { $0.owner == owner }, sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        practices = (try? context.fetch(practiceQuery)) ?? []
        let ids = Set(practices.map(\.id))
        parts = ((try? context.fetch(FetchDescriptor<SavedPart>())) ?? []).filter { ids.contains($0.practiceID) }
        journal = ((try? context.fetch(FetchDescriptor<JournalItem>())) ?? []).filter { ids.contains($0.practiceID) }
    }

    @discardableResult func create(id: UUID, sessionID: UUID, key: UUID, preferences: SessionPreferences) throws -> PracticeRecord {
        if let existing = practices.first(where: { $0.id == id }) { return existing }
        let record = PracticeRecord(id: id, owner: accountID, sessionID: sessionID, key: key, preferences: preferences)
        context.insert(record)
        try save()
        return record
    }

    func setStatus(_ status: String, for id: UUID, issue: String? = nil) throws {
        guard let record = practices.first(where: { $0.id == id }) else { return }
        if status == "ended" && record.status == "incomplete" { return }
        record.status = status; record.issue = issue; record.updatedAt = Date()
        if status == "ended" || status == "incomplete" { record.endedAt = Date() }
        try save()
    }

    func savePart(id: String, practiceID: UUID, speaker: String, text: String, playback: String = "unknown", offsetMilliseconds: Int) throws {
        guard practices.contains(where: { $0.id == practiceID }) else { return }
        if let existing = parts.first(where: { $0.id == id && $0.practiceID == practiceID }) {
            if existing.text.isEmpty && !text.isEmpty { existing.text = text; try save(); return }
            guard existing.text == text else { throw StoreFailure.conflictingContent }
            return
        }
        context.insert(SavedPart(id: id, practiceID: practiceID, speaker: speaker, text: text, playback: playback, offsetMilliseconds: offsetMilliseconds))
        try save()
    }

    func queuePayload(id: String, practiceID: UUID, kind: String, bytes: Data, contentType: String) throws {
        guard practices.contains(where: { $0.id == practiceID }) else { throw StoreFailure.missingPayload }
        let hash = Self.hash(bytes)
        if let existing = journal.first(where: { $0.id == id && $0.practiceID == practiceID }) {
            guard existing.sha256 == hash else { throw StoreFailure.conflictingContent }
            return
        }
        context.insert(JournalItem(id: id, practiceID: practiceID, kind: kind, payload: bytes, fileName: nil, contentType: contentType, sha256: hash))
        try save()
    }

    func queueAudio(turnID: UUID, practiceID: UUID, source: URL) throws {
        guard practices.contains(where: { $0.id == practiceID }) else { throw StoreFailure.missingPayload }
        let id = "audio/\(turnID.uuidString)"
        let bytes = try Data(contentsOf: source)
        guard bytes.count > 44, bytes.count <= 10 * 1024 * 1024 else { throw StoreFailure.invalidAudio }
        let hash = Self.hash(bytes)
        if let existing = journal.first(where: { $0.id == id && $0.practiceID == practiceID }) {
            guard existing.sha256 == hash else { throw StoreFailure.conflictingContent }
            return
        }
        let pendingBytes = journal.filter { $0.kind == "audio" && $0.receipt != "accepted" }.reduce(0) { size, item in
            size + ((item.fileName.flatMap { try? manager.attributesOfItem(atPath: files.appending(path: $0).path)[.size] as? Int }) ?? 0)
        }
        guard pendingBytes + bytes.count <= 200 * 1024 * 1024 else { throw StoreFailure.storageLimit }
        let name = "\(practiceID.uuidString)-\(turnID.uuidString).wav"
        let target = files.appending(path: name)
        try bytes.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? (target as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        context.insert(JournalItem(id: id, practiceID: practiceID, kind: "audio", payload: nil, fileName: name, contentType: "audio/wav", sha256: hash))
        do { try save() } catch { try? manager.removeItem(at: target); throw error }
        try? manager.removeItem(at: source)
    }

    func bytes(for item: JournalItem) throws -> Data {
        let bytes: Data
        if let name = item.fileName { bytes = try Data(contentsOf: files.appending(path: name)) }
        else if let payload = item.payload { bytes = payload }
        else { throw StoreFailure.missingPayload }
        guard Self.hash(bytes) == item.sha256 else { throw StoreFailure.corruptPayload }
        return bytes
    }

    func markAccepted(_ id: String, practiceID: UUID) throws {
        guard let item = journal.first(where: { $0.id == id && $0.practiceID == practiceID }) else { return }
        item.receipt = "accepted"; item.issue = nil
        try save()
    }

    func saveReport(_ data: Data, practiceID: UUID) throws {
        guard let record = practices.first(where: { $0.id == practiceID }) else { return }
        let report = try JSONDecoder().decode(CoachingResponse.self, from: data)
        guard report.validCompleted else { throw StoreFailure.corruptPayload }
        record.reportData = data; record.status = "feedbackReady"; record.issue = nil; record.updatedAt = Date()
        try save()
        // Once the complete report is durable, acknowledged upload bytes are no longer
        // needed for retry. Keep pending items intact for recovery.
        for item in journal where item.practiceID == practiceID && item.receipt == "accepted" {
            if let name = item.fileName {
                do {
                    try manager.removeItem(at: files.appending(path: name))
                    item.fileName = nil
                } catch { continue }
            }
            item.payload = nil
        }
        try save()
    }

    func manifest(for practiceID: UUID) throws -> Data {
        guard let record = practices.first(where: { $0.id == practiceID }) else { throw StoreFailure.missingPayload }
        if let saved = record.manifestData { return saved }
        let entries = journal.filter { $0.practiceID == practiceID }
        let turnIDs = Set(parts.filter { $0.practiceID == practiceID && $0.speaker == "You" }.map(\.id))
        let audio = Set(entries.filter { $0.kind == "audio" }.compactMap { $0.id.split(separator: "/").last.map(String.init) }).union(turnIDs)
        let transcripts = Set(entries.filter { $0.kind == "learnerTranscript" }.compactMap { $0.id.split(separator: "/").last.map(String.init) }).union(turnIDs)
        let agent = entries.filter { $0.kind == "agentTranscript" }.compactMap { item -> ManifestAgent? in
            let fields = item.id.split(separator: "/")
            guard fields.count == 3, let index = Int(fields[2]) else { return nil }
            return ManifestAgent(itemID: String(fields[1]), contentIndex: index)
        }.sorted { $0.itemID == $1.itemID ? $0.contentIndex < $1.contentIndex : $0.itemID < $1.itemID }
        let bytes = try JSONEncoder().encode(UploadManifest(audioTurnIDs: audio.sorted(), transcriptTurnIDs: transcripts.sorted(), agentTranscripts: agent))
        record.manifestData = bytes
        try save()
        return bytes
    }

    func delete(_ id: UUID) throws {
        for item in journal where item.practiceID == id {
            if let name = item.fileName { try? manager.removeItem(at: files.appending(path: name)) }
            context.delete(item)
        }
        for part in parts where part.practiceID == id { context.delete(part) }
        if let record = practices.first(where: { $0.id == id }) { context.delete(record) }
        try save()
    }

    func reconcile() {
        let knownNames = Set(journal.compactMap(\.fileName))
        for url in (try? manager.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)) ?? [] where
            url.pathExtension == "wav" && !knownNames.contains(url.lastPathComponent) {
            let stem = url.deletingPathExtension().lastPathComponent
            // UUIDs are fixed width, so the first 36 characters identify the practice.
            guard stem.count == 73,
                  let practiceID = UUID(uuidString: String(stem.prefix(36))),
                  let turnID = UUID(uuidString: String(stem.suffix(36))),
                  practices.contains(where: { $0.id == practiceID }) else { continue }
            if let bytes = try? Data(contentsOf: url), bytes.count > 44,
               bytes.count <= 10 * 1024 * 1024 {
                context.insert(JournalItem(id: "audio/\(turnID.uuidString)", practiceID: practiceID,
                                           kind: "audio", payload: nil, fileName: url.lastPathComponent,
                                           contentType: "audio/wav", sha256: Self.hash(bytes)))
            }
        }
        try? save()
        for item in journal where item.receipt != "accepted" {
            do { _ = try bytes(for: item) }
            catch {
                item.issue = "Saved upload data is missing or damaged."
                if let record = practices.first(where: { $0.id == item.practiceID }) {
                    record.status = "incomplete"; record.issue = item.issue
                }
            }
        }
        for record in practices where record.status == "active" {
            record.status = "incomplete"; record.issue = "Practice was interrupted before it finished."
        }
        for record in practices {
            if let report = record.reportData,
               (try? JSONDecoder().decode(CoachingResponse.self, from: report).validCompleted) != true {
                record.reportData = nil
                record.status = "incomplete"
                record.issue = "Cached coaching data is damaged. Local conversation remains available."
            }
        }
        try? save()
    }

    private func save() throws { try context.save(); refresh() }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

enum StoreFailure: Error { case conflictingContent, invalidAudio, storageLimit, missingPayload, corruptPayload }
