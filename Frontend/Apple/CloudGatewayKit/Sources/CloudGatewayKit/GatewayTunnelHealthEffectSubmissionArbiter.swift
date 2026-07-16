import Foundation

protocol GatewayTunnelHealthEffectSubmissionExecuting: Sendable {
    /// Implementations enqueue asynchronously and preserve FIFO order.
    func enqueue(_ action: @escaping @Sendable () -> Void)
    func waitForPrecedingActions()
}

private final class GatewayTunnelHealthSerialSubmissionExecutor:
    GatewayTunnelHealthEffectSubmissionExecuting,
    @unchecked Sendable
{
    private let queue = DispatchQueue(
        label: "com.gocloudlaunch.gateway.tunnel.health.effect-submission"
    )

    func enqueue(_ action: @escaping @Sendable () -> Void) {
        queue.async(execute: action)
    }

    func waitForPrecedingActions() {
        queue.sync {}
    }
}

final class GatewayTunnelHealthEffectSubmissionTicket: @unchecked Sendable {
    let generation: UInt64
    let sequence: UInt64
    private weak var arbiter: GatewayTunnelHealthEffectSubmissionArbiter?

    fileprivate init(
        generation: UInt64,
        sequence: UInt64,
        arbiter: GatewayTunnelHealthEffectSubmissionArbiter
    ) {
        self.generation = generation
        self.sequence = sequence
        self.arbiter = arbiter
    }

    func drain() {
        arbiter?.drain(generation: generation, sequence: sequence)
    }
}

final class GatewayTunnelHealthEffectSubmissionArbiter: @unchecked Sendable {
    private enum TicketState {
        case queued
        case submitting
        case started
        case cancelled
        case drained
    }

    private struct TicketRecord {
        var state: TicketState
        var drainRequested = false
        let cancellation: @Sendable () -> Void
        var postDrainRepairs: [@Sendable () -> Void] = []
    }

    private struct TicketKey: Hashable {
        let generation: UInt64
        let sequence: UInt64
    }

    private let lock = NSLock()
    private let executor: any GatewayTunnelHealthEffectSubmissionExecuting
    private let waitsForSubmission: Bool
    private var generation: UInt64?
    private var isOpen = false
    private var nextSequence: UInt64 = 0
    private var tickets: [TicketKey: TicketRecord] = [:]

    init(
        executor: any GatewayTunnelHealthEffectSubmissionExecuting =
            GatewayTunnelHealthSerialSubmissionExecutor(),
        waitsForSubmission: Bool = true
    ) {
        self.executor = executor
        self.waitsForSubmission = waitsForSubmission
    }

    func open(generation: UInt64) {
        lock.lock()
        tickets = tickets.filter {
            switch $0.value.state {
            case .queued, .submitting, .started:
                true
            case .cancelled, .drained:
                false
            }
        }
        self.generation = generation
        isOpen = true
        lock.unlock()
    }

    func closeCurrent(
        onClose: () -> Void = {}
    ) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return nil }
        isOpen = false
        onClose()
        return generation
    }

    func close(
        generation: UInt64,
        onClose: () -> Void = {}
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen, self.generation == generation else { return false }
        isOpen = false
        onClose()
        return true
    }

    @discardableResult
    func submit(
        generation: UInt64,
        onCancelled: @escaping @Sendable () -> Void = {},
        _ submission: @escaping @Sendable (
            GatewayTunnelHealthEffectSubmissionTicket
        ) -> Void
    ) -> Bool {
        lock.lock()
        guard isOpen, self.generation == generation else {
            lock.unlock()
            return false
        }
        nextSequence &+= 1
        let sequence = nextSequence
        let key = TicketKey(generation: generation, sequence: sequence)
        let ticket = GatewayTunnelHealthEffectSubmissionTicket(
            generation: generation,
            sequence: sequence,
            arbiter: self
        )
        tickets[key] = TicketRecord(
            state: .queued,
            cancellation: onCancelled
        )
        executor.enqueue { [self] in
            start(ticket, submission: submission)
        }
        lock.unlock()
        if waitsForSubmission {
            executor.waitForPrecedingActions()
        }
        return true
    }

    func enqueueNormalStop(
        generation: UInt64,
        _ submission: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        executor.enqueue(submission)
        lock.unlock()
    }

    func cancelQueuedAndEnqueueDeadlineStop(
        generation: UInt64,
        _ submission: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        var cancellations: [@Sendable () -> Void] = []
        let queuedKeys = tickets.keys.filter {
            $0.generation == generation && tickets[$0]?.state == .queued
        }.sorted { $0.sequence < $1.sequence }
        for key in queuedKeys {
            tickets[key]?.state = .cancelled
            if let cancellation = tickets[key]?.cancellation {
                cancellations.append(cancellation)
            }
        }
        executor.enqueue(submission)
        lock.unlock()
        for cancellation in cancellations {
            cancellation()
        }
    }

    func addPostDrainRepair(
        generation: UInt64,
        _ repair: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        for key in tickets.keys where key.generation == generation {
            switch tickets[key]?.state {
            case .submitting, .started:
                tickets[key]?.postDrainRepairs.append(repair)
            case .queued, .cancelled, .drained, nil:
                break
            }
        }
        lock.unlock()
    }

    func isCurrentAndOpen(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen && self.generation == generation
    }

    @discardableResult
    func performIfOpen(
        generation: UInt64,
        _ submission: @escaping @Sendable () -> Void
    ) -> Bool {
        submit(generation: generation) { ticket in
            submission()
            ticket.drain()
        }
    }

    func notifyWhenDrained(
        generation: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) {
        enqueueNormalStop(generation: generation, action)
    }

    func notifyAfterOutstandingReservations(
        generation: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) {
        addPostDrainRepair(generation: generation, action)
    }

    func waitForSubmittedEffects() {
        executor.waitForPrecedingActions()
    }

    private func start(
        _ ticket: GatewayTunnelHealthEffectSubmissionTicket,
        submission: @escaping @Sendable (
            GatewayTunnelHealthEffectSubmissionTicket
        ) -> Void
    ) {
        let key = TicketKey(
            generation: ticket.generation,
            sequence: ticket.sequence
        )
        lock.lock()
        guard let state = tickets[key]?.state else {
            lock.unlock()
            return
        }
        guard state == .queued else {
            if state == .cancelled { tickets.removeValue(forKey: key) }
            lock.unlock()
            return
        }
        tickets[key]?.state = .submitting
        lock.unlock()

        submission(ticket)

        lock.lock()
        guard var record = tickets[key], record.state == .submitting else {
            lock.unlock()
            return
        }
        let repairs: [@Sendable () -> Void]
        if record.drainRequested {
            repairs = record.postDrainRepairs
            tickets.removeValue(forKey: key)
        } else {
            record.state = .started
            repairs = []
            tickets[key] = record
        }
        lock.unlock()
        for repair in repairs {
            repair()
        }
    }

    fileprivate func drain(generation: UInt64, sequence: UInt64) {
        let key = TicketKey(generation: generation, sequence: sequence)
        lock.lock()
        guard var record = tickets[key] else {
            lock.unlock()
            return
        }
        let repairs: [@Sendable () -> Void]
        switch record.state {
        case .submitting:
            record.drainRequested = true
            tickets[key] = record
            repairs = []
        case .started:
            repairs = record.postDrainRepairs
            tickets.removeValue(forKey: key)
        case .queued, .cancelled, .drained:
            repairs = []
        }
        lock.unlock()
        for repair in repairs {
            repair()
        }
    }
}

typealias GatewayTunnelHealthEffectGate = GatewayTunnelHealthEffectSubmissionArbiter
