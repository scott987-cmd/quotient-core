import XCTest
@testable import LLMQuotaCore

final class PostLandRepairTests: XCTestCase {
    func testConcreteReviewFindingCreatesSameOwnerRepairExactlyOnce() throws {
        var source = WorkTask(id: "source1", prompt: "实现战斗逻辑", repo: "/flint")
        source.state = .done
        source.branch = "agent/kimi/source1"
        source.platform = .kimi
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"

        var review = WorkTask(
            id: "review1",
            prompt: """
            【审查】复查刚合入 main 的合并 abc1234（来源分支 agent/kimi/source1）。
            \(PostLandRepair.contractMarker)
            产出：把结论写进 reviews/REVIEW-abc1234.md
            """,
            repo: "/flint")
        review.origin = "post-land-review"
        review.state = .done

        let report = """
        # 审查
        ### 1. GameScene.swift:113 — 玩家子弹打不中 bot（高）
        """
        let made = PostLandRepair.reconcile([source, review]) { _ in report }
        XCTAssertEqual(made.count, 1)
        let repair = try XCTUnwrap(made.first)
        XCTAssertEqual(repair.id, "rreview1",
                       "两台 worker 同时对账时不能生成两个逻辑整改任务")
        XCTAssertEqual(repair.origin, "post-land-repair:review1")
        XCTAssertEqual(repair.ownerPlatform, Platform.kimi)
        XCTAssertEqual(repair.ownerRunnerID, "kimi.code")
        XCTAssertTrue(repair.prompt.contains("GameScene.swift:113"))

        XCTAssertTrue(PostLandRepair.reconcile(
            [source, review, repair], reportText: { _ in report }).isEmpty,
            "同一份审查报告只能创建一条整改")
    }

    func testPassingReviewCreatesNoRepair() {
        var review = WorkTask(id: "review2", prompt: "【审查】审查通过",
                              repo: "/flint")
        review.prompt += "\n" + PostLandRepair.contractMarker
        review.origin = "post-land-review"
        review.state = .done
        XCTAssertTrue(PostLandRepair.reconcile([review]) { _ in
            "# 审查\n审查通过：没有发现逻辑问题。"
        }.isEmpty)
    }

    func testPassingProjectReviewQueuesOneHighValueNextRoundForOriginalOwner() throws {
        var source = WorkTask(id: "source2", prompt: "实现一局战斗", repo: "/flint")
        source.state = .done
        source.branch = "agent/kimi/source2"
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"

        var review = WorkTask(
            id: "review-next",
            prompt: """
            【架构复核】项目迭代复盘：main 合并 abc1234（来源分支 agent/kimi/source2）。
            \(PostLandRepair.contractMarker)
            """,
            repo: "/flint")
        review.origin = "post-land-review"
        review.state = .done
        let report = """
        ## 确定问题与证据
        没有确定代码缺陷，实跑证据见上一节。
        复盘通过
        ## 下一轮唯一高价值目标
        打通结算后的再开一局，并保留上一局的选择反馈。
        """

        let made = PostLandRepair.reconcile([source, review]) { _ in report }
        let next = try XCTUnwrap(made.first)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(next.id, "nreview-")
        XCTAssertEqual(next.origin, "post-land-next:review-next")
        XCTAssertEqual(next.ownerPlatform, .kimi)
        XCTAssertEqual(next.ownerRunnerID, "kimi.code")
        XCTAssertTrue(next.prompt.contains("打通结算后的再开一局"))
        XCTAssertFalse(TaskKind.isReview(next.prompt),
                       "下一轮必须是会产出功能的实现任务，落地后才会再次进入复盘")

        XCTAssertTrue(PostLandRepair.reconcile(
            [source, review, next], reportText: { _ in report }).isEmpty,
            "同一个复盘目标只能派一次")
    }

    func testMissingOrUnverifiedNextGoalDoesNotInventWork() {
        var source = WorkTask(id: "source-empty", prompt: "实现", repo: "/flint")
        source.state = .done
        source.branch = "agent/kimi/source-empty"
        var review = WorkTask(
            id: "review-empty",
            prompt: "【架构复核】项目迭代复盘（来源分支 agent/kimi/source-empty）。\n"
                + PostLandRepair.contractMarker,
            repo: "/flint")
        review.origin = "post-land-review"
        review.state = .done

        for report in [
            "## 确定问题与证据\n复盘通过。",
            "## 下一轮唯一高价值目标\n未验证，待定。",
            "## 下一轮唯一高价值目标\n暂无。",
            "## 确定问题与证据\n这里似乎有问题但格式错误。\n## 下一轮唯一高价值目标\n继续做新功能。",
            "## 确定问题与证据\n证据不足，不能声称复盘通过。\n## 下一轮唯一高价值目标\n继续探索战斗反馈。",
            "复盘通过。但是证据仍不足。\n## 下一轮唯一高价值目标\n继续探索战斗反馈。",
            "复盘通过\n## 下一轮唯一高价值目标\n- 改战斗反馈\n- 改结算循环",
        ] {
            XCTAssertTrue(PostLandRepair.reconcile([source, review]) { _ in report }.isEmpty)
        }
    }

    func testMalformedProjectReviewQueuesOneArchitectCorrectionAndKeepsRepoBusy() throws {
        var source = WorkTask(id: "source-bad", prompt: "实现", repo: "/flint")
        source.state = .done
        source.branch = "agent/kimi/source-bad"
        var review = WorkTask(
            id: "review-bad",
            prompt: "【架构复核】项目迭代复盘（来源分支 agent/kimi/source-bad）。\n"
                + PostLandRepair.contractMarker + "\n写入 reviews/REVIEW-bad.md",
            repo: "/flint")
        review.origin = "post-land-review"
        review.state = .done
        let malformed = "证据不足，不能声称复盘通过。\n## 下一轮唯一高价值目标\n待定。"

        let made = PostLandRepair.reconcile([source, review]) { _ in malformed }
        let correction = try XCTUnwrap(made.first)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(correction.id, "creview-")
        XCTAssertEqual(correction.origin, "post-land-review")
        XCTAssertTrue(TaskKind.isArchitectReview(correction.prompt))
        XCTAssertEqual(correction.preferredPlatform, AgentRoles.architectPlatform())
        XCTAssertFalse(AutoRefill.isIdle(repo: "/flint", tasks: [review, correction]))

        XCTAssertTrue(PostLandRepair.reconcile(
            [source, review, correction], reportText: { _ in malformed }).isEmpty,
            "同一张无效报告只能产生一张修正票")
    }

    func testMissingProjectReviewArtifactQueuesCorrectionAndKeepsRepoBusy() throws {
        var source = WorkTask(id: "source-missing", prompt: "实现", repo: "/flint")
        source.state = .done
        source.branch = "agent/kimi/source-missing"
        var review = WorkTask(
            id: "review-missing",
            prompt: "【架构复核】项目迭代复盘（来源分支 agent/kimi/source-missing）。\n"
                + PostLandRepair.contractMarker + "\n写入 reviews/REVIEW-missing.md",
            repo: "/flint")
        review.origin = "post-land-review"
        review.state = .done

        let made = PostLandRepair.reconcile([source, review]) { _ in nil }
        let correction = try XCTUnwrap(made.first)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(correction.origin, "post-land-review")
        XCTAssertTrue(correction.prompt.contains("修正项目迭代复盘报告"))
        XCTAssertFalse(AutoRefill.isIdle(repo: "/flint", tasks: [review, correction]))
    }

    func testCorrectedProjectReviewCanEnterNextRound() throws {
        var source = WorkTask(id: "source-fixed", prompt: "实现", repo: "/flint")
        source.state = .done
        source.branch = "agent/kimi/source-fixed"
        source.ownerPlatform = .kimi
        source.ownerRunnerID = "kimi.code"
        var review = WorkTask(
            id: "review-fixed",
            prompt: "【架构复核】项目迭代复盘（来源分支 agent/kimi/source-fixed）。\n"
                + PostLandRepair.contractMarker + "\n写入 reviews/REVIEW-fixed.md",
            repo: "/flint")
        review.origin = "post-land-review"
        review.state = .done
        let malformed = "报告被截断"
        var correction = try XCTUnwrap(PostLandRepair.reconcile(
            [source, review], reportText: { _ in malformed }).first)
        correction.state = .done
        let fixed = "复盘通过\n## 下一轮唯一高价值目标\n打通结算后再开一局。"

        let made = PostLandRepair.reconcile([source, review, correction]) { task in
            task.id == correction.id ? fixed : malformed
        }
        let next = try XCTUnwrap(made.first { $0.origin == "post-land-next:" + correction.id })
        XCTAssertEqual(next.ownerRunnerID, "kimi.code")
        XCTAssertTrue(next.prompt.contains("打通结算后再开一局"))
    }

    func testHistoricalReviewsAreNotBackfilledIntoAQueueFlood() {
        var old = WorkTask(id: "oldreview", prompt: "【审查】旧格式报告", repo: "/flint")
        old.origin = "post-land-review"
        old.state = .done
        XCTAssertTrue(PostLandRepair.reconcile([old]) { _ in
            "### 1. Old.swift:10 — 历史问题（低）"
        }.isEmpty, "启用机制时不能把所有历史报告一次性翻成新任务")
    }

    func testTaskGraphReadsRealReportAndQueuesRepair() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-land-\(UUID().uuidString)")
        let reviews = repo.appendingPathComponent("reviews")
        try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "### 1. Store.swift:42 — 并发写会丢记录（中）\n".write(
            to: reviews.appendingPathComponent("REVIEW-deadbee.md"),
            atomically: true, encoding: .utf8)

        var source = WorkTask(id: "source3", prompt: "实现存储", repo: repo.path)
        source.state = .done
        source.branch = "agent/codex/source3"
        source.ownerPlatform = .codex
        source.ownerRunnerID = "codex"
        var review = WorkTask(
            id: "review3",
            prompt: "【审查】（来源分支 agent/codex/source3）。"
                + PostLandRepair.contractMarker + " 写入 reviews/REVIEW-deadbee.md",
            repo: repo.path)
        review.origin = "post-land-review"
        review.state = .done

        let repair = try XCTUnwrap(TaskGraph.reconcile([source, review]).first {
            $0.origin == "post-land-repair:review3"
        })
        XCTAssertEqual(repair.state, .queued)
        XCTAssertEqual(repair.ownerRunnerID, "codex")
    }
}
