import Foundation

public protocol FeedbackRetrySchedulingClock: Sendable {
    func now() -> Date
    func sleep(for seconds: TimeInterval) async
}

public struct SystemFeedbackRetryClock: FeedbackRetrySchedulingClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for seconds: TimeInterval) async {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }
}

public struct FeedbackRetryJob: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let request: FeedbackRequest
    public var retryAfter: Date
    public var attempt: Int
    public var lastError: String?

    public init(id: UUID = UUID(), request: FeedbackRequest, retryAfter: Date, attempt: Int = 1, lastError: String? = nil) {
        self.id = id
        self.request = request
        self.retryAfter = retryAfter
        self.attempt = attempt
        self.lastError = lastError
    }

    public var secondsRemaining: Int {
        max(0, Int(ceil(retryAfter.timeIntervalSinceNow)))
    }

    public func secondsRemaining(relativeTo now: Date) -> Int {
        max(0, Int(ceil(retryAfter.timeIntervalSince(now))))
    }
}

public final class FeedbackRetryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [FeedbackRetryJob]
    public let retryDelay: TimeInterval
    private let clock: any FeedbackRetrySchedulingClock

    public init(
        jobs: [FeedbackRetryJob] = [],
        retryDelay: TimeInterval = 5,
        clock: any FeedbackRetrySchedulingClock = SystemFeedbackRetryClock()
    ) {
        self.jobs = jobs
        self.retryDelay = retryDelay
        self.clock = clock
    }

    public var count: Int { lock.withLock { jobs.count } }
    public var allJobs: [FeedbackRetryJob] { lock.withLock { jobs.sorted { $0.retryAfter < $1.retryAfter } } }

    @discardableResult
    public func enqueue(_ request: FeedbackRequest, now: Date? = nil, lastError: String? = nil) -> FeedbackRetryJob {
        let base = now ?? clock.now()
        let job = FeedbackRetryJob(
            request: request,
            retryAfter: base.addingTimeInterval(retryDelay),
            attempt: 1,
            lastError: lastError
        )
        lock.withLock { jobs.append(job) }
        return job
    }

    public func updateRetry(after jobID: UUID, error: String? = nil, now: Date? = nil) {
        let base = now ?? clock.now()
        lock.withLock {
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[index].attempt += 1
            jobs[index].retryAfter = base.addingTimeInterval(retryDelay)
            jobs[index].lastError = error
        }
    }

    public func remove(_ jobID: UUID) {
        lock.withLock { jobs.removeAll { $0.id == jobID } }
    }

    public func clear() {
        lock.withLock { jobs.removeAll() }
    }

    public func countdownSnapshot(now: Date? = nil) -> [FeedbackRetryJob] {
        let base = now ?? clock.now()
        return lock.withLock {
            jobs.sorted { $0.retryAfter < $1.retryAfter }.map { job in
                var copy = job
                copy.retryAfter = base.addingTimeInterval(TimeInterval(job.secondsRemaining(relativeTo: base)))
                return copy
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
