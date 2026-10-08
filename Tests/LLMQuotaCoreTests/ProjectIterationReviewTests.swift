import XCTest
@testable import LLMQuotaCore

final class ProjectIterationReviewTests: XCTestCase {
    func testQualityProjectGetsArchitectOwnedWholeProductReview() {
        let spec = Review.postLandReviewSpec(
            sha: "abc1234",
            branch: "agent/kimi/source1",
            verificationMaterial: "机器验证通过（退出码 0）",
            requiresProjectReview: true)

        XCTAssertEqual(spec.preferredPlatform, AgentRoles.architectPlatform())
        XCTAssertTrue(TaskKind.isArchitectReview(spec.prompt))
        XCTAssertTrue(spec.prompt.contains("真实运行当前 main"))
        XCTAssertTrue(spec.prompt.contains("上一版"))
        XCTAssertTrue(spec.prompt.contains("玩家闭环"))
        XCTAssertTrue(spec.prompt.contains("架构与可维护性"))
        XCTAssertTrue(spec.prompt.contains("下一轮唯一高价值目标"))
        XCTAssertTrue(spec.prompt.contains("正文只写一行"))
        XCTAssertTrue(spec.prompt.contains("单独一行写“复盘通过”"))
        XCTAssertTrue(spec.prompt.contains(PostLandRepair.contractMarker))
        XCTAssertFalse(spec.prompt.contains(ArchitectReview.contractMarker),
                       "项目复盘已经由架构师执行，不能再生成第二张架构复核票")
    }

    func testOrdinaryRepositoryKeepsLightweightReviewLane() {
        let spec = Review.postLandReviewSpec(
            sha: "def5678",
            branch: "agent/qwen/source2",
            verificationMaterial: "没有验证命令",
            requiresProjectReview: false)

        XCTAssertEqual(spec.preferredPlatform, .minimax)
        XCTAssertTrue(spec.prompt.hasPrefix("【审查】"))
        XCTAssertTrue(spec.prompt.contains(ArchitectReview.contractMarker))
        XCTAssertFalse(spec.prompt.contains("下一轮唯一高价值目标"))
    }

    func testPendingProjectReviewKeepsRepositoryBusyBeforeNextRound() {
        var review = WorkTask(
            id: "review1",
            prompt: "【架构复核】项目迭代复盘：main 合并 abc1234",
            repo: "/tmp/game")
        review.origin = "post-land-review"

        XCTAssertFalse(AutoRefill.isIdle(repo: "/tmp/game", tasks: [review]),
                       "项目复盘结束前不能自动进入下一轮")
    }

    func testArchitectProjectFindingReturnsDirectlyToOriginalOwner() throws {
        var source = WorkTask(id: "source1", prompt: "实现战斗", repo: "/tmp/game")
        source.state = .done
        source.branch = "agent/kimi/source1"
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"

        var review = WorkTask(
            id: "review1",
            prompt: """
            【架构复核】项目迭代复盘：main 合并 abc1234（来源分支 agent/kimi/source1）。
            \(PostLandRepair.contractMarker)
            """,
            repo: "/tmp/game")
        review.origin = "post-land-review"
        review.state = .done

        let repairs = PostLandRepair.reconcile(
            [source, review], reportText: { _ in
                "### 1. GameLoop.swift:42 — 结算后无法再开一局（高）"
            })
        XCTAssertEqual(repairs.count, 1)
        let repair = try XCTUnwrap(repairs.first)
        XCTAssertEqual(repair.ownerRunnerID, "kimi.code")
        XCTAssertEqual(repair.origin, "post-land-repair:review1")
        XCTAssertFalse(TaskKind.isArchitectReview(repair.prompt),
                       "架构复盘只负责找根因，整改仍交回实现 Owner")
    }

    func testNextRoundImplementationIsEligibleForAnotherPostLandReview() {
        var next = WorkTask(
            id: "next1",
            prompt: "【项目复盘下一轮】打通结算后的再开一局",
            repo: "/tmp/game")
        next.origin = "post-land-next:review1"

        XCTAssertTrue(Review.isEligibleForPostLandReview(next))
    }
}
