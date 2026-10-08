import Foundation

/// 把“合入后审查”里的具体缺陷变成确定性的整改任务。
///
/// `ReservePool` 只在额度快作废且队列空时取活，适合维护候选，不适合质量闭环。
/// 已经由审查员确认的问题必须立刻入队；否则报告写得再准也只是躺在磁盘上。
public enum PostLandRepair {
    public static let contractMarker = "【整改契约 v1】"
    private static let correctionMarker = "【复盘报告修正 v1】"

    public static func reconcile(_ tasks: [WorkTask]) -> [WorkTask] {
        reconcile(tasks, reportText: loadReport)
    }

    static func reconcile(_ tasks: [WorkTask],
                          reportText: (WorkTask) -> String?) -> [WorkTask] {
        var repairs: [WorkTask] = []
        var knownOrigins = Set(tasks.compactMap(\.origin))
        var knownIDs = Set(tasks.map(\.id))

        for review in tasks where review.origin == "post-land-review"
            && review.state == .done && review.discardedAt == nil
            && review.prompt.contains(contractMarker) {
            let text = reportText(review)
            let parsedFindings = text.map { Self.findings(in: $0) } ?? []
            let sourceBranch = reviewedBranch(in: review.prompt)
            let sourceID = sourceBranch.map {
                String($0.split(separator: "/").last ?? "")
            }
            let source = sourceID.flatMap { id in
                tasks.last(where: { $0.id == id })
            } ?? sourceBranch.flatMap { branch in
                tasks.last(where: {
                    $0.repo == review.repo && $0.branch == branch
                        && $0.origin != "post-land-review"
                })
            }

            if parsedFindings.isEmpty {
                let origin = "post-land-next:" + review.id
                if TaskKind.isArchitectReview(review.prompt),
                   !knownOrigins.contains(origin),
                   let source,
                   let text,
                   isExplicitPass(text),
                   let goal = nextGoal(in: text) {
                    var next = WorkTask(
                        id: "n" + String(review.id.prefix(7)).lowercased(),
                        prompt: """
                        【项目复盘下一轮｜保持原 Agent 项目会话】
                        架构复盘任务 \(review.id) 已确认当前 main 没有需要先返工的确定缺陷，
                        并选出了下一轮唯一高价值目标：

                        > \(goal)

                        只完成这个目标，不顺手扩张其它功能。先从当前 main 实跑并记录基线，
                        完成后跑仓库完整验证和玩家闭环，提供与基线同口径的截图/录屏或性能
                        证据。若实际代码证明前提不成立，停止修改并如实说明，不能用文档更新
                        冒充产品增量。
                        """,
                        repo: review.repo)
                    next.origin = origin
                    next.ownerPlatform = source.ownerPlatform ?? source.platform
                    next.ownerRunnerID = source.ownerRunnerID
                    next.ownerAssignedAt = source.ownerAssignedAt ?? source.startedAt
                    next.preferredPlatform = next.ownerPlatform ?? source.preferredPlatform
                    next.platform = next.ownerPlatform
                    next.profile = source.profile ?? TaskProfile(
                        tier: .standard, risk: .safe, estimatedMinutes: 30,
                        isSelfContained: true,
                        rationale: "项目复盘选出的下一轮唯一高价值目标")
                    next.production = source.production
                    next.note = "项目复盘已通过，下一轮唯一高价值目标已交回原 Agent 项目会话"
                    repairs.append(next)
                    knownOrigins.insert(origin)
                    knownIDs.insert(next.id)
                    continue
                }

                // 架构复盘已经 done 但报告不合约时，不能让 AutoRefill 把仓库
                // 当成空闲并继续旧 PLAN。排一张同岗位修正票，直到得到确定 findings
                // 或严格的“复盘通过 + 单一目标”；这样格式漂移、截断和未验证结论
                // 都 fail closed，而不是静默断开质量反馈环。
                guard TaskKind.isArchitectReview(review.prompt),
                      let sourceBranch,
                      let path = reportPath(in: review.prompt) else { continue }
                let correctionID = "c" + String(review.id.prefix(7)).lowercased()
                guard !knownIDs.contains(correctionID) else { continue }
                let attempt = correctionAttempt(in: review.prompt) + 1
                var correction = WorkTask(
                    id: correctionID,
                    prompt: """
                    【架构复核】修正项目迭代复盘报告（来源分支 \(sourceBranch)）。
                    \(correctionMarker) attempt \(attempt)
                    \(contractMarker) 确定问题会自动交回原 owner 的同一项目会话整改。

                    上一张复盘任务 \(review.id) 已结束，但报告不能驱动质量闭环：没有
                    合约格式的确定 finding，也没有严格的“复盘通过”独立结论行和单行
                    “下一轮唯一高价值目标”。重新读取当前 main、原任务、运行证据与
                    \(path)，补齐缺失的实跑/对比证据后直接修正该报告。

                    若存在确定问题，每条写成：
                    `### N. File.swift:123 — 问题与玩家后果（高/中/低）`
                    若没有确定问题，单独一行写“复盘通过”；随后章节
                    `## 下一轮唯一高价值目标` 的正文只写一行，不加列表、编号或补充段落。
                    不得把未验证猜测写成通过或下一轮任务。只修正 \(path)，不改功能代码。
                    """,
                    repo: review.repo)
                correction.origin = "post-land-review"
                correction.preferredPlatform = AgentRoles.architectPlatform()
                correction.profile = TaskProfile(
                    tier: .standard, risk: .safe, estimatedMinutes: 15,
                    isSelfContained: true,
                    rationale: "复盘报告不合约时修正证据与控制字段，阻止旧路线静默续活")
                correction.note = "复盘报告不合约，已排架构师修正；修正完成前不进入下一轮"
                repairs.append(correction)
                knownIDs.insert(correctionID)
                continue
            }

            let origin = "post-land-repair:" + review.id
            guard !knownOrigins.contains(origin) else { continue }
            if review.prompt.contains(ArchitectReview.contractMarker),
               ArchitectReview.decision(for: review, tasks: tasks) != .uphold {
                continue
            }
            let list = parsedFindings.enumerated().map { i, finding in
                "\(i + 1). \(finding)"
            }.joined(separator: "\n")

            var repair = WorkTask(
                id: "r" + String(review.id.prefix(7)).lowercased(),
                prompt: """
                【合入后审查整改｜保持原 Agent 项目会话】
                审查任务 \(review.id) 对已合入成果发现了以下确定缺陷：

                \(list)

                逐项定位并修复，给每条缺陷补能复现失败形状的回归测试；不要只改
                报告或措辞。修完跑仓库完整验证，并在提交说明里逐条对应上面的编号。
                这是原成果的整改续作，不要扩张无关功能。
                """,
                repo: review.repo)
            repair.origin = origin
            repair.ownerPlatform = source?.ownerPlatform ?? source?.platform
            repair.ownerRunnerID = source?.ownerRunnerID
            repair.ownerAssignedAt = source?.ownerAssignedAt ?? source?.startedAt
            repair.preferredPlatform = repair.ownerPlatform ?? source?.preferredPlatform
            repair.platform = repair.ownerPlatform
            repair.profile = source?.profile
            repair.production = source?.production
            repair.note = "合入后审查发现 \(parsedFindings.count) 条缺陷，已交回原 Agent 项目会话"
            repairs.append(repair)
            knownOrigins.insert(origin)
        }
        return repairs
    }

    private static func reviewedBranch(in prompt: String) -> String? {
        guard let marker = prompt.range(of: "来源分支 ") else { return nil }
        let tail = prompt[marker.upperBound...]
        let branch = tail.prefix {
            !$0.isWhitespace && $0 != "）" && $0 != ")" && $0 != "。"
        }
        return branch.isEmpty ? nil : String(branch)
    }

    private static func reportPath(in prompt: String) -> String? {
        guard let start = prompt.range(of: "reviews/REVIEW-") else { return nil }
        let tail = prompt[start.lowerBound...]
        guard let end = tail.range(of: ".md") else { return nil }
        return String(tail[..<end.upperBound])
    }

    static func findings(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap(ReservePool.findingNote)
    }

    /// 质量项目复盘的结论必须真的影响下一轮，而不是只留在报告里。
    /// 只认模板规定的独立章节；空值和“尚未验证”不会被伪造成实现任务。
    static func nextGoal(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let heading = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## 下一轮唯一高价值目标"
        }) else { return nil }
        var body: [String] = []
        for line in lines.dropFirst(heading + 1) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") { break }
            body.append(line)
        }
        let nonempty = body.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard nonempty.count == 1 else { return nil }
        let goal = nonempty[0]
        guard !goal.hasPrefix("- "), !goal.hasPrefix("* "), !goal.hasPrefix("+ "),
              goal.range(of: #"^\d+[.)]\s"#, options: .regularExpression) == nil
        else { return nil }
        guard !goal.isEmpty, goal.count <= 2_000 else { return nil }
        let compact = goal
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*># "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        let ambiguous = ["无", "暂无", "没有", "待定", "未验证", "不确定"]
        guard !ambiguous.contains(where: { compact.hasPrefix($0) }) else { return nil }
        return goal
    }

    private static func isExplicitPass(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return line == "复盘通过" || line == "复盘通过。"
        }
    }

    private static func correctionAttempt(in prompt: String) -> Int {
        guard let marker = prompt.range(of: correctionMarker + " attempt ") else { return 0 }
        return Int(prompt[marker.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    static func reportText(for review: WorkTask) -> String? {
        loadReport(review)
    }

    private static func loadReport(_ review: WorkTask) -> String? {
        guard let path = reportPath(in: review.prompt) else { return nil }
        return ReviewArtifactCache.load(task: review, path: path) {
            if let branch = review.branch {
                let shown = GitWorkspace.git(["show", "\(branch):\(path)"], in: review.repo)
                if shown.exitCode == 0, !shown.stdout.isEmpty { return shown.stdout }
            }
            return try? String(contentsOf: URL(fileURLWithPath: review.repo)
                .appendingPathComponent(path), encoding: .utf8)
        }
    }
}
