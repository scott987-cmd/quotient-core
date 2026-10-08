import XCTest
@testable import LLMQuotaCore

final class StageObservationSchedulingTests: XCTestCase {
    private var root: URL!
    private var fixtureRepo: URL!
    private var milestone: Milestone.Item!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("observation-scheduling-" + UUID().uuidString)
        fixtureRepo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: fixtureRepo, withIntermediateDirectories: true)
        Paths.appSupportOverride = root.appendingPathComponent("support")
        AskStore.rootOverride = root.appendingPathComponent("shared")
        for args in [["init", "-b", "main"], ["config", "user.name", "fixture"], ["config", "user.email", "fixture@example.invalid"],
                     ["commit", "--allow-empty", "-m", "initial"], ["checkout", "-b", "agent/kimi/source"]] {
            XCTAssertEqual(GitWorkspace.git(args, in: fixtureRepo.path).exitCode, 0)
        }
        try FileManager.default.createDirectory(at: Review.evidenceDir, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: Review.evidenceDir.appendingPathComponent("fixture.png"))
        milestone = .init(repo: fixtureRepo.path, repoName: "fixture", branch: "agent/kimi/source",
            mergeSHA: try XCTUnwrap(GitWorkspace.headSHA(in: fixtureRepo.path)), subject: "checkpoint", landedAt: Date(),
            evidenceFiles: ["fixture.png"], taskID: "source", isCheckpoint: true)
        XCTAssertTrue(Milestone.save([milestone]))
    }
    override func tearDown() {
        Paths.appSupportOverride = nil; AskStore.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }
    private func sourceTask() -> WorkTask {
        var t = WorkTask(id: "source", prompt: "implement", repo: fixtureRepo.path)
        t.branch = milestone.branch; t.state = .running
        t.ownerRunnerID = "kimi.code"; t.ownerPlatform = .kimi
        return t
    }
    private func observation(_ id: String = "eyes1") -> WorkTask {
        var t = WorkTask(id: id, prompt: Milestone.visualCheckPrompt(milestone)!, repo: fixtureRepo.path)
        t.origin = "milestone-eyes"; t.preferredPlatform = .minimax
        return t
    }
    func testEveryVisibleFileMustHaveAnImmutableDigestBeforeConcurrentExecution() throws {
        var m = milestone!
        m.evidenceFiles = ["fixture.png", "missing.png"]
        var eyes = observation(); eyes.prompt = try XCTUnwrap(Milestone.visualCheckPrompt(m))
        XCTAssertNil(StageObservationExecution.validatedSnapshot(eyes, tasks: [sourceTask()], milestones: [m]))
    }
    func testSystemObservationCanRunAlongsideOriginalOwner() {
        var source = sourceTask()
        source.state = .running; source.ownerRunnerID = "kimi.code"; source.ownerPlatform = .kimi
        let eyes = observation()
        XCTAssertEqual(LocalWorkerSlotPlanner.select(ready: [eyes], allTasks: [source, eyes], active: [], maxConcurrentTasks: 2).map(\.id), [eyes.id])
    }
    func testUnknownActiveWorkerAndSharedResourcesRemainExclusive() {
        let eyes = observation()
        XCTAssertTrue(LocalWorkerSlotPlanner.select(ready: [eyes], allTasks: [eyes], active: [.init(taskID: "unknown", repo: eyes.repo)], maxConcurrentTasks: 2).isEmpty)
        var a = sourceTask()
        a.state = .running; a.resourceClaims = ["device:ios-simulator"]
        var b = eyes; b.resourceClaims = a.resourceClaims
        XCTAssertTrue(LocalWorkerSlotPlanner.select(ready: [b], allTasks: [a,b], active: [], maxConcurrentTasks: 2).isEmpty)
    }
    func testOrdinaryOrUnpinnedWorkCannotBypassRepositoryExclusion() {
        var source = sourceTask()
        source.state = .running
        var variants = [WorkTask]()
        var t = observation(); t.origin = "manual"; variants.append(t)
        t = observation(); t.prompt = "【阶段观察 v1】"; variants.append(t)
        t = observation(); t.ownerRunnerID = "minimax.code"; t.ownerPlatform = .minimax; variants.append(t)
        t = observation(); t.graphID = "shared"; variants.append(t)
        for t in variants {
            XCTAssertTrue(LocalWorkerSlotPlanner.select(ready: [t], allTasks: [source,t], active: [], maxConcurrentTasks: 2).isEmpty)
        }
    }
    func testObservationOfAnOlderCommitIsRetiredOnceTheSourceBranchMovesOn() {
        let eyes = observation()
        XCTAssertTrue(StageObservationExecution.reconcileSuperseded([sourceTask(), eyes]).isEmpty,
                      "分支还停在观察时的提交上，单子要留着等执行")
        XCTAssertEqual(GitWorkspace.git(["commit", "--allow-empty", "-m", "owner moved on"],
                                        in: fixtureRepo.path).exitCode, 0)
        let retired = StageObservationExecution.reconcileSuperseded([sourceTask(), eyes])
        XCTAssertEqual(retired.map(\.id), [eyes.id], "分支前进后这张单永远通不过校验，必须收掉")
        XCTAssertEqual(retired.first?.state, .failed)
        XCTAssertNotNil(retired.first?.discardedAt)
        XCTAssertTrue(retired.first?.note?.contains("已前进") == true)

        let reconciled = TaskGraph.reconcile([sourceTask(), eyes])
        XCTAssertEqual(reconciled.first { $0.id == eyes.id }?.state, .failed,
                       "每轮对账必须真的执行这一步，不能只有函数没人调")
    }

    func testExpiredLeftoverLeaseDoesNotShieldAStaleObservationButALiveOneDoes() {
        XCTAssertEqual(GitWorkspace.git(["commit", "--allow-empty", "-m", "owner moved on"],
                                        in: fixtureRepo.path).exitCode, 0)
        let now = Date()
        var leftover = observation()
        leftover.dispatchLeaseID = "old-lease"
        leftover.dispatchLeaseExpiresAt = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(StageObservationExecution.reconcileSuperseded([sourceTask(), leftover], now: now)
            .map(\.id), [leftover.id],
            "两天前就过期的租约只是残留（Flint 实测），不能让过期单永远排着")

        var leased = observation()
        leased.dispatchLeaseID = "live-lease"
        leased.dispatchLeaseExpiresAt = now.addingTimeInterval(60)
        XCTAssertTrue(StageObservationExecution.reconcileSuperseded([sourceTask(), leased], now: now)
            .isEmpty, "执行器正拿着有效租约启动时不能去抢着收单")
    }

    func testObservationIsKeptWhenTheBranchHeadCannotBeRead() {
        let probe = StageObservationExecution.branchHeadProbe
        defer { StageObservationExecution.branchHeadProbe = probe }
        StageObservationExecution.branchHeadProbe = { _, _ in nil }
        XCTAssertTrue(StageObservationExecution.reconcileSuperseded([sourceTask(), observation()]).isEmpty,
                      "读不到分支头只说明不知道，不能据此判过期")
    }

    func testObservationOfALandedOrDiscardedSourceIsRetiredButRunningOnesAreLeftAlone() {
        var landed = sourceTask(); landed.landedAt = Date()
        XCTAssertEqual(StageObservationExecution.reconcileSuperseded([landed, observation()]).count, 1)
        var discarded = sourceTask(); discarded.discardedAt = Date()
        XCTAssertEqual(StageObservationExecution.reconcileSuperseded([discarded, observation()]).count, 1)
        var running = observation(); running.state = .running
        XCTAssertTrue(StageObservationExecution.reconcileSuperseded([landed, running]).isEmpty,
                      "正在跑的观察不归这里管")
    }

    func testCheckpointValidationAndWorkspaceIsolationPreserveOwnerChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eyes-isolation-" + UUID().uuidString)
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        Paths.appSupportOverride = root.appendingPathComponent("support")
        AskStore.rootOverride = root.appendingPathComponent("shared")
        defer { Paths.appSupportOverride = self.root.appendingPathComponent("support"); AskStore.rootOverride = self.root.appendingPathComponent("shared"); try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws -> String {
            let r = GitWorkspace.git(args, in: repo.path, timeout: 5)
            XCTAssertEqual(r.exitCode, 0, r.stderr)
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-b", "main"])
        _ = try git(["config", "user.name", "Isolated fixture"])
        _ = try git(["config", "user.email", "fixture@example.invalid"])
        try "committed source".write(to: repo.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try Data("large asset fixture".utf8).write(to: repo.appendingPathComponent("Assets/model.bin"))
        _ = try git(["add", "."]); _ = try git(["commit", "-m", "initial"])
        _ = try git(["checkout", "-b", "agent/kimi/source"])
        let head = try git(["rev-parse", "HEAD"])
        try "owner uncommitted work".write(to: repo.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: Review.evidenceDir, withIntermediateDirectories: true)
        let frame = Review.evidenceDir.appendingPathComponent("frame.png")
        try Data("immutable frame".utf8).write(to: frame)
        var source = WorkTask(id: "source", prompt: "implement", repo: repo.path)
        source.branch = "agent/kimi/source"; source.ownerRunnerID = "kimi.code"; source.ownerPlatform = .kimi
        let m = Milestone.Item(repo: repo.path, repoName: "fixture", branch: source.branch!, mergeSHA: head,
            subject: "checkpoint", landedAt: Date(), evidenceFiles: ["frame.png"], taskID: source.id, isCheckpoint: true)
        var eyes = WorkTask(id: "eyes1", prompt: try XCTUnwrap(Milestone.visualCheckPrompt(m)), repo: repo.path)
        eyes.origin = "milestone-eyes"; eyes.preferredPlatform = .minimax
        XCTAssertNotNil(StageObservationExecution.validatedSnapshot(eyes, tasks: [source], milestones: [m]))
        var forged = eyes; forged.prompt += "\n另外修改源代码"
        XCTAssertNil(StageObservationExecution.validatedSnapshot(forged, tasks: [source], milestones: [m]))
        var duplicate = eyes; duplicate.id = "eyes2"
        XCTAssertEqual(StageObservationExecution.executionKey(eyes), StageObservationExecution.executionKey(duplicate))
        XCTAssertNotEqual(StageObservationExecution.workspaceKey(eyes), StageObservationExecution.workspaceKey(duplicate))
        let workspace = try GitWorkspace.prepare(repo: repo.path, taskID: eyes.id, platform: .minimax,
            base: head, workspaceKey: StageObservationExecution.workspaceKey(eyes))
        XCTAssertEqual(GitWorkspace.headSHA(in: workspace.path), head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path + "/Assets/model.bin"), "只看画面和写报告不应复制游戏资产，占满实现机器的磁盘")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: workspace.path).appendingPathComponent("source.txt"), encoding: .utf8), "committed source")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("source.txt"), encoding: .utf8), "owner uncommitted work")
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"]), source.branch)
        XCTAssertEqual(GitWorkspace.existingWorkspace(repo: repo.path, platform: .minimax,
            workspaceKey: StageObservationExecution.workspaceKey(eyes))?.path, workspace.path)
        eyes.state = .done
        eyes = try TaskStore.create(eyes, actor: "fixture", reason: "isolated finished observer")
        let oldProbe = GitWorkspace.occupantsProbe
        defer { GitWorkspace.occupantsProbe = oldProbe; TaskStore.resetWrittenRevForTests() }
        GitWorkspace.occupantsProbe = { _ in [12345] }
        XCTAssertEqual(try Archive.run(target: nil).removedWorktrees, 0, "迟到观察进程仍活着时不得回收")
        GitWorkspace.occupantsProbe = { _ in [] }
        XCTAssertEqual(try Archive.run(target: nil).removedWorktrees, 1, "已提交且无活进程的观察工作区走既有归档回收")
        XCTAssertEqual(try git(["rev-parse", "agent/minimax/" + eyes.id]), head, "回收工作区必须保留报告分支")
        try Data("overwritten frame".utf8).write(to: frame)
        XCTAssertNil(StageObservationExecution.validatedSnapshot(eyes, tasks: [source], milestones: [m]))
    }

}
