import Foundation
import CryptoKit

/// 仅固定媒体执行器的阶段观察可以绕过实现写租约。身份键只依赖任务的
/// 不变字段；开工前另查真实 checkpoint，不能因快照更新改变正在持有的锁。
public enum StageObservationExecution {
    public static let runnerID = "minimax.media"
    public struct Snapshot {
        public var sourceID: String
        public var branch: String
        public var head: String
        public var digest: String
    }
    public static func snapshot(_ task: WorkTask) -> Snapshot? {
        guard task.origin == "milestone-eyes", task.graphID == nil,
              task.preferredPlatform == .minimax,
              task.ownerRunnerID == nil || task.ownerRunnerID == runnerID,
              task.ownerPlatform == nil || task.ownerPlatform == .minimax,
              !task.id.isEmpty, task.id.count <= 100,
              task.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              task.prompt.components(separatedBy: .newlines).contains(VisualReviewScope.observationMarker)
        else { return nil }
        func field(_ name: String) -> String? {
            let lines = task.prompt.components(separatedBy: .newlines).filter { $0.hasPrefix(name + "：") }
            guard lines.count == 1 else { return nil }
            let value = String(lines[0].dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        guard let source = field("来源任务"), let branch = field("来源分支"), branch.hasPrefix("agent/"),
              let head = field("证据提交"), head.count == 40, head.allSatisfy(\.isHexDigit),
              let digest = field("证据摘要"),
              digest.split(separator: ",").allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }),
              !MiniMaxMediaRunner.visualFiles(in: task.prompt).isEmpty,
              MiniMaxMediaRunner.visualFiles(in: task.prompt).count == digest.split(separator: ",").count else { return nil }
        return Snapshot(sourceID: source, branch: branch, head: head, digest: digest)
    }
    public static func workspaceKey(_ task: WorkTask) -> String? {
        snapshot(task).map { _ in "observation-" + GitWorkspace.stableKey(repo: task.repo, platform: .minimax) + "-" + task.id }
    }
    public static func executionKey(_ task: WorkTask) -> String {
        let repo = RepoLease.normalize(task.repo)
        guard let s = snapshot(task) else { return repo }
        let identity = [repo, s.sourceID, s.head, s.digest].joined(separator: "|")
        return "stage-observation:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// 对照系统的完整原始提示词和真实字节摘要，人工仿写关键词不能获得例外。
    public static func validatedSnapshot(_ task: WorkTask, tasks: [WorkTask],
                                         milestones: [Milestone.Item] = Milestone.all()) -> Snapshot? {
        guard let s = snapshot(task),
              let source = tasks.first(where: { $0.id == s.sourceID && RepoLease.normalize($0.repo) == RepoLease.normalize(task.repo) }),
              source.branch == s.branch, source.discardedAt == nil, source.landedAt == nil,
              source.ownerRunnerID != runnerID,
              let item = milestones.first(where: {
                  $0.isCheckpoint && $0.taskID == s.sourceID && $0.branch == s.branch && $0.mergeSHA == s.head
                    && RepoLease.normalize($0.repo) == RepoLease.normalize(task.repo)
                    && Milestone.visualCheckPrompt($0) == task.prompt
              }), !item.evidenceFiles.isEmpty,
              StageFindingLoop.evidenceDigests(item.evidenceFiles).joined(separator: ",") == s.digest
        else { return nil }
        let current = GitWorkspace.git(["rev-parse", "--verify", s.branch + "^{commit}"], in: source.repo, timeout: 5)
        guard current.exitCode == 0,
              current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == s.head else { return nil }
        return s
    }
    /// 读分支当前指向的提交；读不到（超时、分支不在）返回 nil。测试注入口。
    public static var branchHeadProbe: (_ repo: String, _ branch: String) -> String? = { repo, branch in
        let r = GitWorkspace.git(["rev-parse", "--verify", branch + "^{commit}"], in: repo, timeout: 5)
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.exitCode == 0 && !sha.isEmpty ? sha : nil
    }

    /// 永远不可能再开跑的阶段观察单，收掉。
    ///
    /// 观察单绑定「来源分支在某一个提交上的画面」。来源一旦被合入或丢弃、换了
    /// 分支、或分支已经前进到别的提交，`validatedSnapshot` 就永远不会再通过，
    /// 单子只会一直排着。2026-09-19 实测：尘途那台机器 11 张这样的单排了两天，
    /// 调度快照一直显示「阶段观察等待匹配的提交与证据」，看起来像在等什么，
    /// 其实什么也等不到。
    ///
    /// 只按确定的事实收：来源任务不在、已合入 / 已丢弃、分支对不上、分支头确实
    /// 不是观察时的提交。分支头读不到、证据摘要暂时对不上这类可能只是还没同步
    /// 完的情况，一律不收。
    public static func reconcileSuperseded(_ tasks: [WorkTask], now: Date = Date()) -> [WorkTask] {
        var latest: [String: WorkTask] = [:]
        for t in tasks { latest[t.id] = t }
        var heads: [String: String?] = [:]
        func head(_ repo: String, _ branch: String) -> String? {
            let key = RepoLease.normalize(repo) + "\u{0}" + branch
            if let cached = heads[key] { return cached }
            let value = branchHeadProbe(repo, branch)
            heads[key] = value
            return value
        }
        var retired: [WorkTask] = []
        for task in latest.values where task.state == .queued && !task.hasLiveDispatchLease(at: now) {
            guard let s = snapshot(task) else { continue }
            let source = latest.values.first {
                $0.id == s.sourceID && RepoLease.normalize($0.repo) == RepoLease.normalize(task.repo)
            }
            let reason: String?
            if let source {
                if source.discardedAt != nil { reason = "来源任务已丢弃" }
                else if source.landedAt != nil { reason = "来源分支已合入" }
                else if source.branch != s.branch { reason = "来源任务已换到别的分支" }
                else if let current = head(source.repo, s.branch), current != s.head {
                    reason = "来源分支已前进到 \(current.prefix(8))，这张单看的是 \(s.head.prefix(8))"
                } else { reason = nil }
            } else {
                reason = "来源任务不在本机账本"
            }
            guard let reason else { continue }
            var done = task
            done.state = .failed
            done.endedAt = now
            done.runnerPID = nil
            done.clearDispatchLease()
            done.discardedAt = now
            done.discardReason = "阶段观察已过期：" + reason
            done.note = "阶段观察已过期，不再排队：" + reason
            retired.append(done)
        }
        return retired
    }

    /// 报告提交保留在分支/attempt 中，只回收无人占用且干净的观察工作区。
    /// 正常收尾即时执行；进程异常退出的遗留目录由既有 archive 路径补收。
    @discardableResult public static func cleanupWorkspace(_ task: WorkTask, dryRun: Bool = false) -> Bool {
        guard let key = workspaceKey(task), task.state == .done || task.state == .failed else { return false }
        let lease = LocalExecutionLease(scope: .repo, key: executionKey(task))
        guard lease.acquire() else { return false }
        defer { lease.release() }
        guard let current = TaskStore.all().first(where: { $0.id == task.id }),
              current.rev == task.rev, current.state == task.state,
              let workspace = GitWorkspace.existingWorkspace(taskID: key),
              workspace.branch == "agent/minimax/" + task.id,
              GitWorkspace.occupantsProbe(workspace.path).isEmpty else { return false }
        let status = GitWorkspace.git(["status", "--porcelain"], in: workspace.path, timeout: 5)
        guard status.exitCode == 0, status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if dryRun { return true }
        return GitWorkspace.git(["worktree", "remove", workspace.path], in: task.repo, timeout: 15).exitCode == 0
    }

}
