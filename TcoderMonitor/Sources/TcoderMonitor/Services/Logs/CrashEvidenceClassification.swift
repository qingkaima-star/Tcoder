//
// 崩溃通道的四态分类（R4，RD-21）。这里只回答一个问题：
// **这份候选文件到底提供了什么程度的证据**，并且把结论同时交给两头：
// 事件（只有 `.confirmed` 有）与台账记录（四态都有，各自带原因与文件位置）。
//
// 整改前的形状是「一条布尔 + 一个兜底事件」：`isCrashReport` 判进通道，
// 通道里取不出证据就 `synthesizedEvent` 造一条崩溃。四态被压成一个"是"，
// 于是「读不动」「内容坏了」「只是名字像」三种未知全都长成了一次真崩溃。
//

import Foundation

/// 一份候选文件过完崩溃通道的结果。
struct CrashChannelOutcome: Sendable {
    /// 只有确认崩溃才会有事件；其余三态返回空数组。
    var events: [LogEvent] = []
    /// 四态记录：`.confirmed` 每事件一条，其余三态每文件一条。
    var records: [CrashEvidenceRecord] = []

    /// **这条是"少报"那一半的开关。**
    ///
    /// 崩溃通道吃掉一份文件之后，普通行解析还要不要跑它：
    /// 真解析出事件时才许吃（同一份文件两套通道各算一次会把一次崩溃拆成两条 cluster），
    /// 疑似 / 解析失败 / 读失败时**必须继续走行解析**，
    /// 否则一份只是名字像崩溃的日志，它真实的 ERROR 行会整批消失
    /// （实测：`diagnostic.log` 被推进通道后 `errorCount` 从 3 变成 0）。
    var suppressLineEvents: Bool { events.isEmpty == false }
}

extension CrashReportParser {

    /// 整份 reading 过崩溃通道：先试 `.ips`（两段 JSON），再试纯文本报告，
    /// 两条都取不出证据时按「有没有报告形状」分成解析失败 / 疑似报告。
    static func crashChannel(reading: LogFileReading) -> CrashChannelOutcome {
        guard isCrashCandidate(reading.url, role: reading.role) else { return CrashChannelOutcome() }
        let path = reading.url.path
        let modifiedAt = reading.modifiedAt

        func fileRecord(_ state: CrashEvidenceState, reason: String?, text: String?) -> CrashChannelOutcome {
            CrashChannelOutcome(events: [], records: [
                CrashEvidenceRecord(path: path,
                                    state: state,
                                    reason: reason,
                                    // 文件级记录没有事件，所以时间一律不可用；
                                    // 名字里带时刻的报告（Apple 命名法）例外，标成 .reportFileName，
                                    // 让"这份大概在什么时候"仍然可查，但它**不参与任何计数**。
                                    eventDate: dateFromFileName(path),
                                    eventTimeSource: dateFromFileName(path) == nil ? .unavailable : .reportFileName,
                                    fileModifiedAt: modifiedAt,
                                    identity: text.map { reportIdentity(from: [$0]).identity } ?? AppBuildIdentity(),
                                    signature: nil,
                                    incidentID: text.flatMap { incidentIDPattern.firstGroup(in: $0, 1) }),
            ])
        }

        if reading.readFailed {
            return fileRecord(.readFailed,
                              reason: reading.readFailure ?? "读取失败（原因未记录）",
                              text: nil)
        }
        guard let text = readText(reading.url) else {
            // `readText` 只在「读不到」或「0 字节」时返回 nil，两种情况的诚实表达不一样。
            if reading.sizeBytes > 0 {
                return fileRecord(.readFailed,
                                  reason: "文件声明 \(reading.sizeBytes) 字节，却一个字节都没读出来",
                                  text: nil)
            }
            return fileRecord(.suspected, reason: "文件为空（0 字节），没有任何事件证据", text: nil)
        }
        guard trimmed(text).isEmpty == false else {
            return fileRecord(.suspected, reason: "文件只有空白内容，没有任何事件证据", text: text)
        }

        let diagnostic = parseDiagnosticReport(text: text, path: path, modifiedAt: modifiedAt)
        if diagnostic.isEmpty == false {
            return confirmedOutcome(diagnostic, path: path, modifiedAt: modifiedAt)
        }
        let plain = parseCrashText(text: text, path: path, modifiedAt: modifiedAt)
        if plain.isEmpty == false {
            return confirmedOutcome(plain, path: path, modifiedAt: modifiedAt)
        }

        // 两条通道都取不出事件。区分「内容坏了」与「根本不是报告」：
        // 有报告独有的机器字段名 = 解析失败（这份确实该能读出来，是我们读不动它）；
        // 一个都没有 = 疑似（它只是名字或目录像崩溃报告）。
        if hasReportShape(text) {
            return fileRecord(.parseFailed,
                              reason: "内容有报告字段（如 Exception Type / incident_id），但取不出可信的崩溃类型、线程或堆栈",
                              text: text)
        }
        return fileRecord(.suspected,
                          reason: "只有文件名或目录指向崩溃报告，内容里没有任何崩溃特征",
                          text: text)
    }

    /// 确认崩溃：把每条事件转成一条记录（一份报告可以含多次崩溃）。
    static func confirmedOutcome(_ events: [LogEvent], path: String, modifiedAt: Date) -> CrashChannelOutcome {
        let records = events.filter { $0.isContinuation == false }.map { event in
            CrashEvidenceRecord(path: path,
                                state: .confirmed,
                                reason: nil,
                                eventDate: event.date,
                                eventTimeSource: event.eventTimeSource,
                                fileModifiedAt: modifiedAt,
                                identity: event.appIdentity ?? AppBuildIdentity(),
                                signature: crashSignature(from: event) ?? emptyToNil(normalize(event.message)),
                                incidentID: event.incidentID,
                                lineNumber: event.lineNumber)
        }
        return CrashChannelOutcome(events: events, records: records)
    }

    /// 「这份内容是一份报告」的形状判据。大小写不敏感，且**只在内容里找**，不看文件名。
    static func hasReportShape(_ text: String) -> Bool {
        let lower = text.lowercased()
        return reportShapeMarkers.contains { lower.contains($0) }
    }
}
