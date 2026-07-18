//  PlanningCoordinator.swift
//  会话异步编排的单一状态源（PDR CP-1.3 / CP-2.3）。

import Foundation
#if canImport(Combine)
import Combine
#endif

public struct PendingPOIResolution: Identifiable, Sendable {
    public var id: UUID { constraintID }
    public let constraintID: UUID
    public let mention: String
    public let candidates: [POICandidate]
    public let canSkip: Bool
}

@MainActor
public final class PlanningCoordinator: ObservableObject, Identifiable {
    public nonisolated let id: UUID
    @Published public private(set) var session: PlanningSession
    @Published public private(set) var isInterpreting = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var pendingPOIResolution: PendingPOIResolution?
    @Published public private(set) var lastConflict: PlanningConflict?

    private let provider: IntentUnderstandingProvider
    private let resolver: POIResolving
    private let source: POIDataSource
    private let store: PlanningSessionStore

    public init(intent: TripIntent, provider: IntentUnderstandingProvider,
                resolver: POIResolving, source: POIDataSource,
                store: PlanningSessionStore = .init()) {
        let sessionID = UUID()
        id = sessionID
        self.provider = provider
        self.resolver = resolver
        self.source = source
        self.store = store
        session = PlanningSession(id: sessionID, state: .clarifying, intent: intent)
        session.messages.append(.init(
            role: .assistant,
            content: "你计划去\(intent.destination.name) \(intent.days) 天。还有必须去的地点、固定预约，或同行人的步行限制吗？"
        ))
        persistDraft()
    }

    public init(session: PlanningSession, provider: IntentUnderstandingProvider,
                resolver: POIResolving, source: POIDataSource,
                store: PlanningSessionStore = .init()) {
        id = session.id
        self.provider = provider
        self.resolver = resolver
        self.source = source
        self.store = store
        self.session = session
        if self.session.state == .generating || self.session.state == .failedRecoverable {
            self.session.state = .clarifying
        }
        updateReadiness()
        persistDraft()
    }

    public func send(_ text: String) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isInterpreting else { return }
        errorMessage = nil
        lastConflict = nil
        isInterpreting = true
        session.messages.append(.init(role: .user, content: message))
        session.updatedAt = .now
        persistDraft()
        let requestedRevision = session.intent.revision
        let currentQuestion = ClarificationPolicy.evaluate(session.intent).question
        do {
            let response = try await provider.interpret(.init(
                intent: session.intent,
                recentMessages: session.messages,
                userMessage: message,
                currentQuestion: currentQuestion
            ))
            guard requestedRevision == session.intent.revision else { isInterpreting = false; return }
            session.intent = try IntentMerger.applying(response.operations, to: session.intent)
            session.pendingAmbiguities.removeAll()
            appendUncertainties(response.uncertainties)
            appendMentions(response.poiMentions)
            if !response.assistantText.isEmpty {
                session.messages.append(.init(role: .assistant, content: response.assistantText))
            }
            try await resolveNextPOIIfNeeded()
            updateReadiness()
        } catch is CancellationError {
            isInterpreting = false
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "这条要求暂时没有整理成功，内容已保留。"
            session.state = .failedRecoverable
        }
        isInterpreting = false
        session.updatedAt = .now
        persistDraft()
    }

    public func resumePendingWork() async {
        guard !isInterpreting, pendingPOIResolution == nil else { return }
        do {
            try await resolveNextPOIIfNeeded()
            updateReadiness()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "地点核验失败，请重试。"
            session.state = .failedRecoverable
        }
        persistDraft()
    }

    public func selectPOI(_ candidate: POICandidate) async {
        guard let pending = pendingPOIResolution,
              let index = session.intent.poiConstraints.firstIndex(where: { $0.id == pending.constraintID }) else { return }
        session.intent.poiConstraints[index].resolvedPOIID = candidate.id
        session.intent.poiConstraints[index].resolvedName = candidate.name
        session.intent.revision += 1
        pendingPOIResolution = nil
        session.messages.append(.init(role: .assistant, content: "已确认“\(candidate.name)”。"))
        do {
            try await resolveNextPOIIfNeeded()
            updateReadiness()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "地点核验失败，请重试。"
            session.state = .failedRecoverable
        }
        persistDraft()
    }

    public func skipPendingPOI() {
        guard let pending = pendingPOIResolution,
              let constraint = session.intent.poiConstraints.first(where: { $0.id == pending.constraintID }),
              constraint.requirement != .mustVisit else { return }
        session.intent.poiConstraints.removeAll { $0.id == pending.constraintID }
        session.intent.revision += 1
        pendingPOIResolution = nil
        updateReadiness()
        persistDraft()
    }

    public func removePOIConstraint(_ id: UUID) {
        session.intent.poiConstraints.removeAll { $0.id == id }
        session.pendingAmbiguities.removeAll()
        if pendingPOIResolution?.constraintID == id { pendingPOIResolution = nil }
        session.intent.revision += 1
        updateReadiness()
        persistDraft()
    }

    public func setPOIRequirement(_ requirement: POIRequirement, for id: UUID) {
        guard let index = session.intent.poiConstraints.firstIndex(where: { $0.id == id }) else { return }
        session.intent.poiConstraints[index].requirement = requirement
        session.intent.revision += 1
        updateReadiness()
        persistDraft()
    }

    public func markGenerating() { session.state = .generating; persistDraft() }
    public func markCompleted() { session.state = .completed; store.delete() }
    public func discardDraft() { session.state = .cancelled; store.delete() }
    public func markConflict(_ conflict: PlanningConflict) {
        errorMessage = conflict.message
        lastConflict = conflict
        session.state = .conflict
        persistDraft()
    }

    public func applyRepair(_ option: RepairOption) throws {
        session.intent = try IntentMerger.applying(option.patches, to: session.intent)
        errorMessage = nil
        lastConflict = nil
        updateReadiness()
        persistDraft()
    }

    private func appendMentions(_ mentions: [IntentPOIMention]) {
        for mention in mentions {
            let normalized = mention.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            if let existing = session.intent.poiConstraints.firstIndex(where: {
                $0.mention == normalized || $0.resolvedName == normalized
            }) {
                session.intent.poiConstraints[existing].requirement = mention.requirement
                session.intent.poiConstraints[existing].assignedDay = mention.assignedDay
                session.intent.poiConstraints[existing].fixedArrivalMinute = mention.fixedArrivalMinute
                session.intent.poiConstraints[existing].minimumStayMinutes = mention.minimumStayMinutes
            } else {
                session.intent.poiConstraints.append(.init(
                    mention: normalized,
                    requirement: mention.requirement,
                    assignedDay: mention.assignedDay,
                    fixedArrivalMinute: mention.fixedArrivalMinute,
                    minimumStayMinutes: mention.minimumStayMinutes
                ))
            }
        }
        if !mentions.isEmpty { session.intent.revision += 1 }
    }

    private func appendUncertainties(_ uncertainties: [IntentUncertainty]) {
        session.pendingAmbiguities.append(contentsOf: uncertainties.map { uncertainty in
            IntentAmbiguity(path: uncertainty.path,
                            message: uncertainty.reason,
                            isBlocking: uncertainty.confidence < 0.65)
        })
    }

    private func resolveNextPOIIfNeeded() async throws {
        guard pendingPOIResolution == nil,
              let index = session.intent.poiConstraints.firstIndex(where: { $0.resolvedPOIID == nil }) else { return }
        if session.intent.destination.adcode == nil {
            let geocoded = try await source.geocodeCity(session.intent.destination.name)
            session.intent.destination.adcode = geocoded.adcode
        }
        guard let adcode = session.intent.destination.adcode else { return }
        let constraint = session.intent.poiConstraints[index]
        switch try await resolver.resolve(mention: constraint.mention, adcode: adcode, anchor: nil) {
        case let .resolved(candidate):
            session.intent.poiConstraints[index].resolvedPOIID = candidate.id
            session.intent.poiConstraints[index].resolvedName = candidate.name
            session.intent.revision += 1
            try await resolveNextPOIIfNeeded()
        case let .ambiguous(candidates):
            pendingPOIResolution = PendingPOIResolution(constraintID: constraint.id,
                                                        mention: constraint.mention,
                                                        candidates: candidates,
                                                        canSkip: constraint.requirement != .mustVisit)
            session.state = .resolvingPOI
        case .notFound:
            let blocking = constraint.requirement == .mustVisit
            session.pendingAmbiguities.append(.init(
                message: "没有找到“\(constraint.mention)”的可靠地点。",
                isBlocking: blocking
            ))
            if blocking { session.state = .resolvingPOI }
        }
    }

    private func updateReadiness() {
        guard pendingPOIResolution == nil else { session.state = .resolvingPOI; return }
        guard !session.pendingAmbiguities.contains(where: \.isBlocking) else {
            session.state = .clarifying
            return
        }
        let decision = ClarificationPolicy.evaluate(session.intent)
        session.state = decision.isReady ? .ready : .clarifying
        if let question = decision.question,
           session.messages.last?.content != question.prompt {
            session.messages.append(.init(role: .assistant, content: question.prompt))
        }
    }

    private func persistDraft() {
        session.updatedAt = .now
        try? store.save(session)
    }
}
