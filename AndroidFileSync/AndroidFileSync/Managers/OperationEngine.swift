import Foundation
import SwiftUI
internal import Combine

@MainActor
final class OperationEngine: ObservableObject {

    enum OperationState {
        case pending
        case running
        case completed(success: Bool, message: String)
    }

    struct LiveOperation: Identifiable {
        let id = UUID()
        let packageName: String
        let displayName: String
        let actionType: AppManager.AppOperationType
        let groupId: UUID
        var state: OperationState = .pending
    }

    struct OperationGroup: Identifiable {
        let id: UUID
        let actionVerb: String
        var operations: [LiveOperation]
        var finishedAt: Date? = nil

        var totalCount: Int { operations.count }
        var completedCount: Int {
            operations.filter {
                if case .completed = $0.state { return true }
                return false
            }.count
        }
        var isFinished: Bool { completedCount == totalCount }
        var currentRunningName: String? {
            operations.first(where: { if case .running = $0.state { return true }; return false })?.displayName
        }
        var color: Color {
            switch operations.first?.actionType {
            case .uninstall:  return .red
            case .disable:    return .orange
            case .enable:     return .green
            case .backup(_):  return .blue
            case .install(_): return .green
            case .clearData:  return .orange
            case .clearCache: return .orange
            case .forceStop:  return .secondary
            default:          return .blue
            }
        }
    }

    @Published private(set) var groups: [OperationGroup] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    weak var deviceManager: DeviceManager? = nil
    weak var uploadManager: UploadManager? = nil
    weak var downloadManager: DownloadManager? = nil

    var activeGroups: [OperationGroup] { groups.filter { !$0.isFinished } }
    var activeGroupCount: Int { activeGroups.count }
    var isBusy: Bool { !activeGroups.isEmpty }
    var recentlyFinishedGroups: [OperationGroup] {
        groups.filter { $0.isFinished }
    }

    func isPackageBusy(_ package: String) -> Bool {
        activeGroups.flatMap(\.operations).contains { op in
            if op.packageName != package { return false }
            if case .completed = op.state { return false }
            return true
        }
    }

    var runningOperationsCount: Int {
        groups.flatMap(\.operations).filter {
            if case .running = $0.state { return true }
            return false
        }.count
    }

    var isTransferActive: Bool {
        let uploadsActive = !(uploadManager?.activeUploads.values.filter { !$0.isComplete }.isEmpty ?? true)
        let downloadsActive = !(downloadManager?.activeDownloads.values.filter { !$0.isComplete }.isEmpty ?? true)
        return uploadsActive || downloadsActive
    }

    var isWireless: Bool {
        deviceManager?.connectionType == .wireless
    }

    var operationLimit: Int {
        if isWireless && isTransferActive {
            return 2
        }
        return Int.max
    }

    func processQueue() {
        let limit = operationLimit
        var currentRunning = runningOperationsCount
        
        guard currentRunning < limit else { return }
        
        for g in groups where !g.isFinished {
            for pendingOp in g.operations {
                if case .pending = pendingOp.state {
                    if canStart(pendingOp) {
                        startOperation(pendingOp, groupId: g.id)
                        currentRunning += 1
                        if currentRunning >= limit {
                            return
                        }
                    }
                }
            }
        }
    }

    private func canStart(_ op: LiveOperation) -> Bool {
        if runningOperationsCount >= operationLimit {
            return false
        }

        let allOps = groups.flatMap(\.operations)
        let isRunning = allOps.contains { otherOp in
            if otherOp.packageName != op.packageName { return false }
            if case .running = otherOp.state { return true }
            return false
        }
        if isRunning { return false }
        
        let firstPending = allOps.first { otherOp in
            if otherOp.packageName != op.packageName { return false }
            if case .pending = otherOp.state { return true }
            return false
        }
        return firstPending?.id == op.id
    }

    typealias Executor = (LiveOperation) async -> (Bool, String)
    typealias OnGroupComplete = (UUID) async -> Void

    private var executors: [UUID: Executor] = [:]
    private var onGroupComplete: OnGroupComplete?

    func setGroupCompleteHandler(_ handler: @escaping OnGroupComplete) {
        onGroupComplete = handler
    }

    func submit(operations: [LiveOperation], groupId: UUID, actionVerb: String, executor: @escaping Executor) {
        let group = OperationGroup(id: groupId, actionVerb: actionVerb, operations: operations)
        executors[groupId] = executor
        groups.append(group)

        processQueue()
    }

    private func startOperation(_ op: LiveOperation, groupId: UUID) {
        guard let groupIdx = groups.firstIndex(where: { $0.id == groupId }),
              let opIdx = groups[groupIdx].operations.firstIndex(where: { $0.id == op.id }) else { return }

        groups[groupIdx].operations[opIdx].state = .running

        guard let executor = executors[groupId] else { return }
        let runningOp = groups[groupIdx].operations[opIdx]
        let opId = op.id

        let task = Task {
            let (success, message) = await executor(runningOp)
            if Task.isCancelled {
                await onOperationComplete(runningOp, groupId: groupId, success: false, message: "Cancelled")
            } else {
                await onOperationComplete(runningOp, groupId: groupId, success: success, message: message)
            }
            activeTasks.removeValue(forKey: opId)
        }
        activeTasks[opId] = task
    }

    private func onOperationComplete(_ op: LiveOperation, groupId: UUID, success: Bool, message: String) async {
        guard let groupIdx = groups.firstIndex(where: { $0.id == groupId }),
              let opIdx = groups[groupIdx].operations.firstIndex(where: { $0.id == op.id }) else { return }

        groups[groupIdx].operations[opIdx].state = .completed(success: success, message: message)

        processQueue()

        if let updatedGroupIdx = groups.firstIndex(where: { $0.id == groupId }),
           groups[updatedGroupIdx].isFinished {
            groups[updatedGroupIdx].finishedAt = Date()
            executors.removeValue(forKey: groupId)
            await onGroupComplete?(groupId)

            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                groups.removeAll { $0.id == groupId }
            }
        }
    }

    func cancelPending(in groupId: UUID) {
        guard let groupIdx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        for i in groups[groupIdx].operations.indices {
            let op = groups[groupIdx].operations[i]
            switch op.state {
            case .pending:
                groups[groupIdx].operations[i].state = .completed(success: false, message: "Cancelled")
            case .running:
                groups[groupIdx].operations[i].state = .completed(success: false, message: "Cancelled")
                if let task = activeTasks[op.id] {
                    task.cancel()
                    activeTasks.removeValue(forKey: op.id)
                }
            default:
                break
            }
        }
    }

    func cancelAllPending() {
        for group in groups {
            cancelPending(in: group.id)
        }
    }
}
