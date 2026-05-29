import Foundation

public actor RunCoordinator {
    private let sensorAcquirer: any RawSensorAcquiring
    private let contextDeriver: any VirtualContextDeriving
    private let payloadMapper: any BackendPayloadMapping
    private let apiClient: any RecommendationAPIClient
    private let feedbackQueue: FeedbackRetryQueue
    private let requestIDGenerator: any RecommendationRequestIDGenerating
    private let topK: Int
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        sensorAcquirer: any RawSensorAcquiring,
        contextDeriver: any VirtualContextDeriving,
        payloadMapper: any BackendPayloadMapping,
        apiClient: any RecommendationAPIClient,
        feedbackQueue: FeedbackRetryQueue,
        requestIDGenerator: any RecommendationRequestIDGenerating = DefaultRecommendationRequestIDGenerator(),
        topK: Int = 3
    ) {
        self.sensorAcquirer = sensorAcquirer
        self.contextDeriver = contextDeriver
        self.payloadMapper = payloadMapper
        self.apiClient = apiClient
        self.feedbackQueue = feedbackQueue
        self.requestIDGenerator = requestIDGenerator
        self.topK = topK
    }

    deinit {
        for task in retryTasks.values {
            task.cancel()
        }
    }

    public func runRecommendation(virtualUsers: [VirtualUser], questionnaire: QuestionnaireState) async -> RunState {
        var state = RunState(phase: .acquiring)
        let acquisitionStart = Date()
        let snapshot = await sensorAcquirer.acquireSnapshot(deadline: RawSensorFreezer.deadlineSeconds)
        state.snapshot = snapshot
        state.timingEvents.append(
            TimingEvent(
                phase: "acquisition",
                startedAt: acquisitionStart,
                endedAt: Date(),
                detail: snapshot.statuses.keys.sorted().joined(separator: ",")
            )
        )

        state.phase = .deriving
        let derivingStart = Date()
        let contexts = virtualUsers.map { contextDeriver.derive(snapshot: snapshot, virtualUser: $0, questionnaire: questionnaire) }
        state.contexts = contexts
        state.timingEvents.append(
            TimingEvent(
                phase: "derive",
                startedAt: derivingStart,
                endedAt: Date(),
                detail: "contexts=\(contexts.count)"
            )
        )

        state.phase = .recommending
        let recommendBatchStart = Date()
        let recommendations = await withTaskGroup(of: (RecommendationResult, TimingEvent).self, returning: [RecommendationResult].self) { group in
            for context in contexts {
                let requestID = requestIDGenerator.nextRequestID(virtualUserKey: context.virtualUser.key, snapshot: snapshot)
                let request = payloadMapper.recommendPayload(context: context, requestID: requestID, topK: topK)
                group.addTask {
                    let startedAt = Date()
                    let result = await self.apiClient.recommend(request, virtualUserKey: context.virtualUser.key)
                    let event = TimingEvent(
                        phase: "recommend_\(context.virtualUser.key)",
                        startedAt: startedAt,
                        endedAt: Date(),
                        detail: result.isSuccess ? "success" : (result.errorMessage ?? "failure")
                    )
                    return (result, event)
                }
            }

            var results: [RecommendationResult] = []
            for await (result, event) in group {
                results.append(result)
                state.timingEvents.append(event)
            }
            return results.sorted { $0.virtualUserKey < $1.virtualUserKey }
        }
        state.results = recommendations
        state.timingEvents.append(
            TimingEvent(
                phase: "results",
                startedAt: recommendBatchStart,
                endedAt: Date(),
                detail: "success=\(recommendations.filter(\.isSuccess).count);failure=\(recommendations.filter { !$0.isSuccess }.count)"
            )
        )
        state.phase = .awaitingTrueScene
        return state
    }

    public func submitFeedback(selectedScene: RecoScene, from state: RunState, quality: FeedbackQuality? = nil) async -> RunState {
        var next = state
        next.selectedTrueScene = selectedScene.name

        let measuredQuality = measuredFeedbackQuality(from: state, overridingWith: quality)
        next.feedbackQuality = measuredQuality?.isEmpty == false ? measuredQuality : nil

        next.timingEvents.append(
            TimingEvent(
                phase: "true_scene_selected",
                startedAt: Date(),
                endedAt: Date(),
                detail: selectedScene.name
            )
        )

        let jobs = state.results.compactMap { result -> FeedbackRequest? in
            guard result.isSuccess else { return nil }
            return payloadMapper.feedbackPayload(result: result, acceptedScene: selectedScene, quality: next.feedbackQuality)
        }
        next.feedbackJobs = jobs

        guard !jobs.isEmpty else {
            next.retryQueueCount = feedbackQueue.count
            next.retryJobs = feedbackQueue.allJobs
            next.phase = .completed
            return next
        }

        next.phase = .sendingFeedback
        let feedbackStart = Date()
        for job in jobs {
            let outcome = await apiClient.sendFeedback(job)
            switch outcome {
            case .success:
                next.timingEvents.append(
                    TimingEvent(
                        phase: "feedback_\(job.requestID)",
                        startedAt: Date(),
                        endedAt: Date(),
                        detail: "success"
                    )
                )
            case .failure(let error):
                let retryJob = feedbackQueue.enqueue(job, lastError: String(describing: error))
                next.timingEvents.append(
                    TimingEvent(
                        phase: "feedback_\(job.requestID)",
                        startedAt: Date(),
                        endedAt: Date(),
                        detail: "queued_retry"
                    )
                )
                scheduleRetry(for: retryJob)
            }
        }
        next.timingEvents.append(TimingEvent(phase: "feedback_batch", startedAt: feedbackStart, endedAt: Date(), detail: "jobs=\(jobs.count)"))
        next.retryQueueCount = feedbackQueue.count
        next.retryJobs = feedbackQueue.allJobs
        next.phase = next.retryQueueCount > 0 ? .retryingFeedback : .completed
        return next
    }

    public func currentRetryJobs() async -> [FeedbackRetryJob] {
        feedbackQueue.allJobs
    }

    public func retryQueuedFeedbackNow() async -> [FeedbackRetryJob] {
        let jobs = feedbackQueue.allJobs
        for job in jobs {
            let outcome = await apiClient.sendFeedback(job.request)
            switch outcome {
            case .success:
                feedbackQueue.remove(job.id)
                retryTasks[job.id]?.cancel()
                retryTasks[job.id] = nil
            case .failure(let error):
                feedbackQueue.updateRetry(after: job.id, error: String(describing: error))
                if retryTasks[job.id] == nil, let updated = feedbackQueue.allJobs.first(where: { $0.id == job.id }) {
                    scheduleRetry(for: updated)
                }
            }
        }
        return feedbackQueue.allJobs
    }

    private func measuredFeedbackQuality(from state: RunState, overridingWith quality: FeedbackQuality?) -> FeedbackQuality? {
        let dwellTimeSec = measuredDwellTimeSec(from: state)
        let merged = FeedbackQuality(
            dwellTimeSec: quality?.dwellTimeSec ?? dwellTimeSec,
            playedRatioPct: quality?.playedRatioPct,
            nextAction: quality?.nextAction
        )
        return merged.isEmpty ? nil : merged
    }

    private func measuredDwellTimeSec(from state: RunState) -> Int? {
        guard let resultsEndedAt = state.timingEvents.last(where: { $0.phase == "results" })?.endedAt else { return nil }
        return max(0, Int(Date().timeIntervalSince(resultsEndedAt)))
    }

    private func scheduleRetry(for job: FeedbackRetryJob) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRetryLoop(for: job.id)
        }
        retryTasks[job.id]?.cancel()
        retryTasks[job.id] = task
    }

    private func runRetryLoop(for jobID: UUID) async {
        while true {
            let snapshot = feedbackQueue.allJobs
            guard let current = snapshot.first(where: { $0.id == jobID }) else {
                retryTasks[jobID] = nil
                return
            }

            let secondsRemaining = current.secondsRemaining(relativeTo: Date())
            if secondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                continue
            }

            let outcome = await apiClient.sendFeedback(current.request)
            switch outcome {
            case .success:
                feedbackQueue.remove(jobID)
                retryTasks[jobID] = nil
                return
            case .failure(let error):
                feedbackQueue.updateRetry(after: jobID, error: String(describing: error))
            }
        }
    }

}
