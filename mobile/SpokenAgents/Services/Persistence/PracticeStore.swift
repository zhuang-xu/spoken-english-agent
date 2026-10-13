import CryptoKit
import Foundation
import SwiftData

@MainActor final class PracticeStore: ObservableObject {
    @Published private(set) var practices: [PracticeRecord] = []
    @Published private(set) var parts: [SavedPart] = []
    @Published private(set) var journal: [JournalItem] = []
    @Published private(set) var accountID: String
    private(set) var accountGeneration = UUID()

    private let container: ModelContainer
    private let context: ModelContext
    private let files: URL
    private let manager = FileManager.default
    private let fileQueue: DispatchQueue
    // Optional I/O boundary observer permits deterministic interruption tests.
    private let afterAudioFileWrite: (@Sendable (URL) -> Void)?
    private var uploadingPractices = Set<UUID>()

    init(directory: URL? = nil, accountID: String = "local", fileQueue: DispatchQueue? = nil,
         afterAudioFileWrite: (@Sendable (URL) -> Void)? = nil) throws {
        self.afterAudioFileWrite = afterAudioFileWrite
        self.fileQueue = fileQueue ?? DispatchQueue(label: "spoken.files", qos: .utility, attributes: .concurrent)
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
        accountGeneration = UUID()
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

    func discardUncapturedTurn(_ turnID: UUID, practiceID: UUID) throws {
        let id = turnID.uuidString
        guard !journal.contains(where: { $0.practiceID == practiceID && $0.id.hasSuffix("/" + id) }) else {
            throw StoreFailure.conflictingContent
        }
        for part in parts where part.practiceID == practiceID && part.id == id && part.text.isEmpty {
            context.delete(part)
        }
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

    /// Live recording path: prepare bytes and persist the file off the main actor,
    /// then commit only journal metadata through this actor's SwiftData context.
    func queueRecordedAudio(turnID: UUID, practiceID: UUID, source: URL) async throws {
        let owner = accountID
        let epoch = accountGeneration
        guard practices.contains(where: { $0.id == practiceID }) else { throw StoreFailure.missingPayload }
        let pending = journal.filter { $0.kind == "audio" && $0.receipt != "accepted" }
            .compactMap { $0.fileName }.map { files.appending(path: $0) }
        let prepared = try await fileWork {
            let bytes = try Data(contentsOf: source)
            guard bytes.count > 44, bytes.count <= 10 * 1024 * 1024 else { throw StoreFailure.invalidAudio }
            let pendingBytes = pending.reduce(0) { total, url in
                total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            }
            guard pendingBytes + bytes.count <= 200 * 1024 * 1024 else { throw StoreFailure.storageLimit }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return (bytes, hash)
        }
        guard accountID == owner, accountGeneration == epoch, practices.contains(where: { $0.id == practiceID }) else {
            throw StoreFailure.missingPayload
        }
        let id = "audio/\(turnID.uuidString)"
        if let existing = journal.first(where: { $0.id == id && $0.practiceID == practiceID }) {
            guard existing.sha256 == prepared.1 else { throw StoreFailure.conflictingContent }
            await removeFile(source)
            return
        }
        let name = "\(practiceID.uuidString)-\(turnID.uuidString)-\(UUID().uuidString).wav"
        let target = files.appending(path: name)
        let afterWrite = afterAudioFileWrite
        do {
            try await fileWork {
                try prepared.0.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try (target as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
                afterWrite?(target)
            }
            guard accountID == owner, accountGeneration == epoch, practices.contains(where: { $0.id == practiceID }) else {
                throw StoreFailure.missingPayload
            }
            // Another suspended save may have committed this turn in the meantime.
            if let existing = journal.first(where: { $0.id == id && $0.practiceID == practiceID }) {
                guard existing.sha256 == prepared.1 else { throw StoreFailure.conflictingContent }
                await removeFile(target)
            } else {
                // Recheck quota at the serialized metadata commit: another save
                // could have completed while file preparation was suspended.
                let currentPending = journal.filter { $0.kind == "audio" && $0.receipt != "accepted" }
                    .reduce(0) { total, item in
                        total + ((item.fileName.flatMap {
                            try? manager.attributesOfItem(atPath: files.appending(path: $0).path)[.size] as? Int
                        }) ?? 0)
                    }
                guard currentPending + prepared.0.count <= 200 * 1024 * 1024 else { throw StoreFailure.storageLimit }
                let item = JournalItem(id: id, practiceID: practiceID, kind: "audio", payload: nil,
                                       fileName: name, contentType: "audio/wav", sha256: prepared.1)
                context.insert(item)
                do { try save() } catch { context.delete(item); throw error }
            }
            await removeFile(source)
        } catch {
            await removeFile(target)
            throw error
        }
    }

    func bytes(for item: JournalItem) throws -> Data {
        let bytes: Data
        if let name = item.fileName { bytes = try Data(contentsOf: files.appending(path: name)) }
        else if let payload = item.payload { bytes = payload }
        else { throw StoreFailure.missingPayload }
        guard Self.hash(bytes) == item.sha256 else { throw StoreFailure.corruptPayload }
        return bytes
    }

    /// Snapshot model values on the main actor; read and hash immutable bytes on
    /// a background task. No SwiftData object crosses the actor boundary.
    func uploadBytes(for item: JournalItem) async throws -> Data {
        let url = item.fileName.map { files.appending(path: $0) }
        let payload = item.payload
        let hash = item.sha256
        return try await fileWork {
            let bytes: Data
            if let url { bytes = try Data(contentsOf: url) }
            else if let payload { bytes = payload }
            else { throw StoreFailure.missingPayload }
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard actual == hash else { throw StoreFailure.corruptPayload }
            return bytes
        }
    }

    private func fileWork<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            fileQueue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return value
    }

    private func removeFile(_ url: URL) async {
        // Cleanup must still run when the caller has been cancelled.
        await withCheckedContinuation { continuation in
            fileQueue.async {
                try? FileManager.default.removeItem(at: url)
                continuation.resume()
            }
        }
    }

    func beginUpload(_ practiceID: UUID) -> Bool { uploadingPractices.insert(practiceID).inserted }
    func endUpload(_ practiceID: UUID) { uploadingPractices.remove(practiceID) }

    func uploadIsCurrent(practiceID: UUID, owner: String, generation: UUID,
                         itemID: String, hash: String) -> Bool {
        accountID == owner && accountGeneration == generation && practices.contains { $0.id == practiceID }
            && journal.contains { $0.practiceID == practiceID && $0.id == itemID && $0.sha256 == hash && $0.receipt == "pending" }
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
            guard stem.count == 73 || stem.count == 110,
                  let practiceID = UUID(uuidString: String(stem.prefix(36))),
                  let turnID = UUID(uuidString: String(stem.dropFirst(37).prefix(36))),
                  stem.count == 73 || UUID(uuidString: String(stem.suffix(36))) != nil,
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
