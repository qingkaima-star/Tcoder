/// OWNER: WS-X3 TestSplit —— 自 PerfLogsBorderlessTests.swift 拆出，合成违规样例必须被本流尺子抓到、扫描面非零。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension PerfLogsBorderlessTests {

    /// 脏样本里第 1、2 条是 `415f0f0` 上**真实存在过**的代码（改前），不是稻草人。
    func test_scannersCatchSyntheticViolations() {
        let preFixChip = """
            Text(item.sizeBytes.map { Live.bytes($0) } ?? Live.missing)
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.tertiary)
            """
        let preFixCount = """
            Text("已附加 \\(NumberFormat.grouped(attachedItems.count)) 个文件")
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.tertiary)
            """
        let singleLine = #"Text(Live.percent(fraction)).foregroundStyle(.tertiary)"#
        let dirtyTertiary = [
            (path: "Views/Fake.swift", content: preFixChip),
            (path: "Views/Fake.swift", content: preFixCount),
            (path: "Views/Fake.swift", content: singleLine),
        ]
        XCTAssertEqual(Self.tertiaryOnMeasuredValues(in: dirtyTertiary).count, 3,
                       "跨行链与同行两种形状必须都抓到，否则三页的 0 命中只是扫描器看不见")

        let cleanTertiary = [
            (path: "Views/Fake.swift", content: #"Text("·").foregroundStyle(.tertiary)"#),
            (path: "Views/Fake.swift", content: """
                Text(DateFormat.full.string(from: health.computedAt))
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(.tertiary)
                """),
            (path: "Views/Fake.swift", content: """
                Text("来源文件 \\(cluster.sourceFile)")
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                """),
        ]
        XCTAssertTrue(Self.tertiaryOnMeasuredValues(in: cleanTertiary).isEmpty,
                      "路径与时间戳是合法的次要元数据，误伤就等于逼调用点再造一档灰")

        // 链必须**封顶**：兄弟语句里的测得值不该记到这条链上。
        let bounded = """
            Text("机身 \\(Live.text(snapshot))")

            Text("·").foregroundStyle(.tertiary)
            """
        XCTAssertTrue(Self.tertiaryOnMeasuredValues(
            in: [(path: "Views/Fake.swift", content: bounded)]).isEmpty,
                      "修饰链越界吃进了上面的兄弟语句 —— 会把合法用法判成违规")

        XCTAssertEqual(Self.interactiveTintOnTiles(in: [(path: "V/F.swift", content:
            "MetricTile(label: \"CPU\", value: v, tint: Theme.Semantic.accent.textColor)")]).count, 1,
                       "accent 涂在读数上没抓到 → 总工点名的那条病灶会漏")
        XCTAssertEqual(Self.interactiveTintOnTiles(in: [(path: "V/F.swift", content:
            "DisclosureGroup { x }.tint(Theme.Semantic.accent.textColor)")]).isEmpty, true,
                       "控件的 .tint() 用 accent 是合法交互语义，误伤就会被改回灰、丢掉可点性")

        XCTAssertEqual(Self.seriesColoredTiles(in: [(path: "V/F.swift", content:
            "tint: ChartSeries.color(ChartSeries.disk),")]).count, 1,
                       "序列色涂在数字上没抓到（HEAD 第 104/121 行就是这个形状）")
        XCTAssertTrue(Self.seriesColoredTiles(in: [(path: "V/F.swift", content:
            "MiniBarGauge(fraction: f, tint: role.graphicColor)")]).isEmpty,
                       "量表条与曲线用序列/语义色是合法的，不该被这条误伤")

        XCTAssertEqual(Self.areaOpacityDefinitionsNotUsingToken(in: [(path: "V/F.swift", content:
            "static let areaTopOpacity = 0.16")]).count, 1,
                       "字面量又回来了却没红 —— 正是「令牌定义了没人用」的复发形状")
        XCTAssertTrue(Self.areaOpacityDefinitionsNotUsingToken(in: [(path: "V/F.swift", content:
            "static let areaTopOpacity = Theme.Palette.Opacity.gradientAreaSoft")]).isEmpty,
                      "合规写法被误伤")
        XCTAssertTrue(Self.areaOpacityDefinitionsNotUsingToken(in: [(path: "V/F.swift", content:
            ".init(color: color.opacity(areaTopOpacity), location: 0)")]).isEmpty,
                      "使用处（没有 `=`）不该被当成定义行")

        XCTAssertEqual(Self.categoryPaletteUses(in: [(path: "V/F.swift", content:
            "LineMark(...).foregroundStyle(Theme.Chart.color(at: 0))")]).count, 1)

        XCTAssertEqual(Self.symbolCountPerStruct(named: "HealthRing(", in: [(path: "V/H.swift", content: """
            struct HealthHero: View {
                HealthRing(score: nil)
                HealthRing(score: 82)
            }
            """)])["V/H.swift.HealthHero"], 2,
                   "同一 struct 内两枚环没数出来 → 「一页两枚主角」判据失效")

        // 页头扫描器：本流真养过的那份形状必须被抓到，而普通视图不得误伤。
        XCTAssertEqual(Self.pageHeaderTypeDeclarations(in: [(path: "Views/PerfLogs/Fake.swift", content:
            "struct PerfLogsPageHeader<Actions: View>: View {")]).count, 1,
                       "页头声明扫描器失灵 → 页面目录里的第二套页头会漏")
        XCTAssertTrue(Self.pageHeaderTypeDeclarations(in: [(path: "Views/PerfLogs/Fake.swift", content: """
            struct LiveNumber: View {
            struct NoteLine: View {
            """)]).isEmpty, "普通视图被误判成页头 → 三家会被逼着把组件改名绕守卫")
    }

    func test_groupSpacingScannerCatchesTightContainerAndIgnoresLooseOne() {
        let dirty = """
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                GlassSection("系统资源") { tiles }
            }
            """
        let clean = """
            VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                GlassSection("系统资源") { tiles }
            }
            """
        let nested = """
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                GlassSection("进程分组") {
                    Button { doThing() } label: { Text("x") }
                }
            }
            """
        let afterClose = """
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("只有文字")
            }
            GlassSection("不相干") { x }
            """
        func one(_ text: String) -> [(path: String, content: String)] {
            [(path: "Views/Fake.swift", content: text)]
        }
        XCTAssertEqual(Self.containersTighteningGroups(in: one(dirty)).count, 1,
                       "16pt 包着 GlassSection 没抓到 → 这条判据是假的")
        XCTAssertTrue(Self.containersTighteningGroups(in: one(clean)).isEmpty,
                      "group(32) 被误伤，页面就不肯用 32 了")
        XCTAssertEqual(Self.containersTighteningGroups(in: one(nested)).count, 1,
                       "容器内部还有嵌套大括号时判据必须仍然看得见 GlassSection")
        XCTAssertTrue(Self.containersTighteningGroups(in: one(afterClose)).isEmpty,
                      "容器闭合之后的 GlassSection 不该算在它头上（块越界）")
    }

    func test_sourceScannerActuallySeesOwnedFiles() throws {
        let files = try ownedFiles()
        let paths = Set(files.map(\.path))
        for probe in ["Views/PerfLogs/ChartChrome.swift",
                      "Views/Performance/PerformanceSystemTiles.swift",
                      "Views/Health/HealthView.swift",
                      "Views/Logs/LogsView.swift"] {
            XCTAssertTrue(paths.contains(probe), "扫不到 \(probe)，路径口径变了")
        }
    }

}
