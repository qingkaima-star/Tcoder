# Tcoder 全站 UI「简约无界」重构 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Tcoder 九页从"三层灰底 + 约 80 处投影 + 67% 文字挤在 10–12pt"改成单一地面、零卡面、排版撑层级的简约无界风格，同时一字不删地保留全部诚实性信息。

**Architecture:** 先换**表面模型的取值**（不是加令牌、不是加抽象）：内容层从 `.regularMaterial` 改成"什么都不画"，唯一一处投影从三层公共尾巴移进新增的 `.floating` 层。因为 40 处 `GlassSection` 与 29 处 `MetricTile` 都走同一套 `surface(layer:shape:)`，基座一个提交就让九页同时变干净——三条页面流接到的已经是干净底，它们只做重排与去倾向色。

**Tech Stack:** Swift 6.3.3 / SwiftUI / macOS SDK 26.5，部署下限 macOS 14（不变），SwiftPM 可执行 target，语言模式 `.v5`（不得改）。测试 XCTest。

**Spec:** `docs/superpowers/specs/2026-09-20-borderless-minimal-ui-redesign-design.md`（执行者**必须同读**，本计划从它论证）

---

## Global Constraints

逐条抄自 spec，每个任务的隐含要求都包含本节：

- **风格契约 1**：地面只一层，浅 `#F1F1F3` / 深 `#1C1C1E`。内容区不存在第二种填充。
- **风格契约 2**：分组只靠 micro-label + 留白；无卡面、无描边、无图标底色。
- **风格契约 3**：井是唯一例外，`#EAEAEC`（浅）/ `#2A2A2C`（深）+ 0.5pt 分隔线，只给表格/日志/代码块。
- **风格契约 4**：`heroMetric 56` → `metricNumber 34` → `body 13` → `microLabel 10`；主读数一律纯墨。
- **风格契约 5**：颜色只承载语义（健康分档、风险、日志等级、增/删）；数据序列默认灰阶。
- **风格契约 6**：投影全仓 1 处，只给 `.floating`。
- **风格契约 7**：删顶部 9 枚 chip 条；侧栏纯文字行 + 系统原生选中。
- **风格契约 8**：页边距 24 / 分组间 32 / 页级段落 40 / 组内 16 / 列表行 8。
- 全仓文字 **≥ 10pt** 硬下限；承载实时数字的档位必须 `monospacedDigit`。
- 部署下限 macOS 14 不变；`glassEffect` 与 `#available(macOS 26.0, *)` **只允许出现在 `Design/Glass.swift`**。
- 视图签名 `XxxView(report: ProjectReport?)` 冻结；`Models/**`、`Services/**`、`Package.swift` 不得改。
- 新文件 ≤ 800 行（`SelfScanDogfoodTests` 棘轮 `ceiling = 0`）。
- 文案简体中文；数字走 `NumberFormat` / `ByteFormat` / `DateFormat`。
- **不得借美化之名删信息**：`ShellCopy` 三态句式、覆盖率口径说明、报告生成时间、`historyTruncated` 窗口标注、零证据不得给满分——一律保留，只许降排版层级。
- 编译一律走锁：`./scripts/locked_build.sh build|test`；禁止裸 `swift build`。
- 并行拍图必须 `SWITCH_MODE=argv` + 各自 `CAPTURE_SANDBOX` + 各自输出目录（`single` 模式写全机共享的 `com.tcoder.monitor` defaults 域）。
- 每条扫描型守卫**必须配元测试**（造一个违规样本确认它会红）。

---

## 文件结构

**M0 总工（基座，落 main）**

| 动作 | 路径 | 责任 |
|---|---|---|
| Modify | `Sources/TcoderMonitor/Design/Glass.swift` | 表面系统唯一闸门：四层的画法、玻璃可用性、投影唯一落点 |
| Modify | `Sources/TcoderMonitor/Design/ThemeTokens.swift` | `Surface.ground/well/control/ink`、`Typo` 新链 + `groupLabel`、`Spacing.group/pageMargin`、`Layout` 宽度、删 `Elevation.card/raised` |
| Modify | `Sources/TcoderMonitor/Design/SharedComponents.swift` | `MetricTile` 去面改纯墨；新增 `ReadoutStrip` |
| Modify | `Sources/TcoderMonitor/Design/GlassComponents.swift` | `GlassSection` 改 micro-label 分组（不画面）；`GlassCard` 保留给井/控件/浮层 |
| Create | `Sources/TcoderMonitor/Design/DataTable.swift` | 从 `Views/CodeGit/CodeGitTable.swift` **git mv** 上提（跨 6 目录共用的列系统） |
| Modify | `Tests/TcoderMonitorTests/TableHeaderConvergenceTests.swift` | 路径断言 `Views/CodeGit/CodeGitTable.swift` → `Design/DataTable.swift`（含元测试的合成样本） |
| Modify | `Tests/TcoderMonitorTests/DesignTokenTests.swift` | 字号链与 ≥10pt 断言随新令牌更新 |
| Create | `Tests/TcoderMonitorTests/BorderlessSurfaceGuardTests.swift` | 本轮基座侧守卫（纯函数扫描器 + 元测试） |

**M1 三条流**：只碰各自名下 `Views/**` 与各自新建的 `Tests/**`、各自 Obsidian 笔记。见 Part B。

**M2 总工**：`docs/九页实拍读数.md`、`README.md`、`TcoderMonitor/AGENTS.md` 所有权表。

---

## Part A — M0 基座（总工单点，串行前置）

### Task 1: 令牌换血（ThemeTokens）

**Files:**
- Modify: `Sources/TcoderMonitor/Design/ThemeTokens.swift`

**Interfaces:**
- Produces: `Theme.Palette.Surface.ground/well/control/ink`（`Color`）、`Theme.Typo.groupLabel`（`TypeToken`）、`Theme.Typo.heroMetric=56 / metricNumber=34 / metricMid=22 / pageTitle=20`、`Theme.Spacing.group=32 / pageMargin=24`、`Theme.Layout.maxWidthOverview=1200`、`TypeToken.tracking: CGFloat`

- [ ] **Step 1: 先改守卫，让它红**

在 `Tests/TcoderMonitorTests/DesignTokenTests.swift` 里把字号链断言替换成新的期望链（**只改期望，不改实现**）：

```swift
func test_typeScale_isBorderlessLadder() {
    // 风格契约 4：跨度拉到 5:1 以上（旧值 40/28/18/17/13 只有 4:1，
    // 且 122 次 Typo 引用里 67% 挤在 10–12pt、大字档只占 6% → 「没有主次」）
    XCTAssertEqual(Theme.Typo.heroMetric.size, 56)
    XCTAssertEqual(Theme.Typo.metricNumber.size, 34)
    XCTAssertEqual(Theme.Typo.metricMid.size, 22)
    XCTAssertEqual(Theme.Typo.pageTitle.size, 20)
    XCTAssertEqual(Theme.Typo.groupLabel.size, 10)
    XCTAssertEqual(Theme.Typo.groupLabel.tracking, 0.6, accuracy: 0.001)
    XCTAssertGreaterThan(Theme.Typo.heroMetric.size / Theme.Typo.microLabel.size, 5)
}
```

Run: `./scripts/locked_build.sh test --filter DesignTokenTests`
Expected: FAIL（`groupLabel` 不存在 → 编译错也算预期的"红"）

- [ ] **Step 2: 给 `TypeToken` 加 tracking 字段**

`ThemeTokens.swift` 的 `struct TypeToken` 里，在 `lineSpacing` 之后加**带默认值**的字段（带默认值才不会打断 12 处既有成员式初始化）：

```swift
    struct TypeToken {
        let name: String
        let size: CGFloat
        let weight: Font.Weight
        let design: Font.Design
        let monospacedDigits: Bool
        let lineSpacing: CGFloat
        /// 字距（pt）。无界风格里分区标题是唯一的分组线索，靠加字距把它
        /// 从正文里拎出来，而不是靠底色或描边。
        var tracking: CGFloat = 0

        var font: Font {
            let base = Font.system(size: size, weight: weight, design: design)
            let sized = monospacedDigits ? base.monospacedDigit() : base
            return tracking == 0 ? sized : sized.tracking(tracking)
        }
    }
```

- [ ] **Step 3: 改字号值 + 新增 `groupLabel`**

`enum Typo` 内改四行、加一行，并把 `groupLabel` 放进 `all`：

```swift
        static let heroMetric = TypeToken(name: "heroMetric", size: 56, weight: .bold, design: .default, monospacedDigits: true, lineSpacing: 4)
        static let metricNumber = TypeToken(name: "metricNumber", size: 34, weight: .semibold, design: .default, monospacedDigits: true, lineSpacing: 4)
        static let metricMid = TypeToken(name: "metricMid", size: 22, weight: .semibold, design: .default, monospacedDigits: true, lineSpacing: 3)
        static let pageTitle = TypeToken(name: "pageTitle", size: 20, weight: .semibold, design: .default, monospacedDigits: false, lineSpacing: 2)
        /// 分区标题（风格契约 2）。**它取代 `cardTitle` 成为分组唯一标题档**：
        /// 无界面里标题必须比内容更轻更安静，13pt semibold 会被读成"一块面板的名字"。
        static let groupLabel = TypeToken(name: "groupLabel", size: 10, weight: .medium, design: .default, monospacedDigits: false, lineSpacing: 2, tracking: 0.6)
```

`all` 与 `numericTiers` 各加 `groupLabel`（`numericTiers` 不加——它非等宽）。

⚠️ **`metricMid` 必须同步抬到 22**。旧链 `heroMetric > metricNumber > metricMid > pageTitle > cardTitle` 由 `DesignTokenTests` 钉住；只抬 `pageTitle` 到 20 而 `metricMid` 留 18 会破链，报的是"字号顺序"而不是"值不对"，容易误判成别人改坏了。

- [ ] **Step 4: 新增四个地面令牌**

`enum Palette` 的 `enum Surface` 内追加（`DualColor` 已在 `Design/ColorToken.swift`）：

```swift
        /// 唯一页面底色（风格契约 1）。参考图两处取样对比 1.00:1 = 全页只有一个面。
        static let ground = DualColor(lightHex: 0xF1F1F3, darkHex: 0x1C1C1E).color
        /// 井：内容层唯一允许的实心底（风格契约 3），只给表格/日志/代码块。
        static let well = DualColor(lightHex: 0xEAEAEC, darkHex: 0x2A2A2C).color
        /// 控件层在 macOS ≤15 的实心兜底。
        static let control = DualColor(lightHex: 0xFFFFFF, darkHex: 0x2D2D2F).color
        /// 主读数纯墨（风格契约 4）。
        ///
        /// **为什么不能用 `.primary`**：macOS 的 `labelColor` 是 85% 不透明黑，
        /// 铺在 `ground` 上合成出来约 `#262626`——实测正是重构前全页最暗像素 `#2F2F2F` 的来源。
        /// 参考图最暗像素是 `#000000`。所以 34pt 及以上的主读数必须显式用 `ink`。
        static let ink = DualColor(lightHex: 0x0A0A0A, darkHex: 0xF2F2F5).color
```

- [ ] **Step 5: 间距与版面**

```swift
    enum Spacing {
        // …既有 xxs…xxl、section、gutter、chip、cardPadding、tilePadding 不动…
        /// 主分组间距（风格契约 8）。旧值 `md`=16 与卡内条目间距同数 → 读不出组界。
        static let group: CGFloat = 32
        /// 页面左右内边距。
        static let pageMargin: CGFloat = 24
        /// 卡片内边距：20 → 24。
        // cardPadding 的值直接改成 24（保留名字，46 处调用点不用动）
    }
```

`Layout.maxWidthOverview` 1120 → 1200。`Elevation` 删 `card` 与 `raised`（Task 2 会移走唯一引用），保留 `flat` 与 `overlay`。

- [ ] **Step 6: 跑守卫确认绿**

Run: `./scripts/locked_build.sh test --filter DesignTokenTests`
Expected: PASS（新链 + ≥10pt 下限 + monospacedDigit 全绿）

- [ ] **Step 7: Commit**

```bash
git add Sources/TcoderMonitor/Design/ThemeTokens.swift Tests/TcoderMonitorTests/DesignTokenTests.swift
git commit -m "feat(M0-令牌): 无界字号链 56/34/22/20 + groupLabel + 四个地面令牌"
```

---

### Task 2: 表面系统换血（Glass.swift）

**Files:**
- Modify: `Sources/TcoderMonitor/Design/Glass.swift`
- Create: `Tests/TcoderMonitorTests/BorderlessSurfaceGuardTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `Surface.ground/well/control/ink`、`Elevation.overlay`
- Produces: `GlassLayer` 四 case（`.content` / `.contentInset` / `.chrome` / `.floating`）、`View.surface(layer:shape:)` 签名不变

- [ ] **Step 1: 写失败的守卫**

`BorderlessSurfaceGuardTests.swift`。扫描器写成**纯函数**（喂 `[(path, content)]` 吐违规），这样能用合成输入双向元测试——照 `TableHeaderConvergenceTests` 的房内做法：

```swift
import Foundation
import XCTest
@testable import TcoderMonitor

/// 风格契约 1/3/6 的机器守卫：内容层不得画面，投影只许一处。
///
/// 本轮病因恰恰是「令牌定义了但零引用」（`Surface.card` 全仓无人用），
/// 所以这里既查「画了不该画的」，也查「定义了没人用的」——只查前者会原样复发。
final class BorderlessSurfaceGuardTests: XCTestCase {

    // MARK: 扫描器（纯函数）

    /// `.shadow(` 的命中行（整行注释豁免）。
    static func shadowHits(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { f in
            f.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .map { ($0.offset + 1, String($0.element)) }
                .filter { _, line in
                    !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                        && line.contains(".shadow(")
                }
                .map { "\(f.path):\($0.0)" }
        }
    }

    /// `Design/` 里定义了但全仓零引用的 `Theme.Palette.Surface.*` 成员名。
    static func unreferencedSurfaceMembers(
        defined: [String], references: [String]) -> [String] {
        defined.filter { name in
            !references.contains { $0.hasSuffix(".\(name)") }
        }
    }

    // MARK: 真源码

    private static func sourceFiles(under subpath: String) throws -> [(path: String, content: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TcoderMonitor")
        let dir = root.appendingPathComponent(subpath)
        guard let urls = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }) else { return [] }
        return urls.filter { $0.pathExtension == "swift" }.compactMap {
            guard let s = try? String(contentsOf: $0, encoding: .utf8) else { return nil }
            return (String($0.path.replacingOccurrences(of: root.path + "/", with: "")), s)
        }
    }

    func test_shadowOnlyInsideFloatingBranch() throws {
        let design = try sourceFiles(under: "Design")
        let hits = Self.shadowHits(in: design)
        XCTAssertEqual(hits.count, 1, "投影必须全仓唯一，实测：\(hits)")
        let glass = design.first { $0.path.hasSuffix("Glass.swift") }
        XCTAssertNotNil(glass)
        XCTAssertTrue(glass!.content.contains("case .floating"),
                      "唯一一处投影必须落在 .floating 分支里")
    }

    func test_surfaceTokensAreActuallyUsed() throws {
        let all = try sourceFiles(under: "")
        let defined = ["ground", "well", "control", "ink", "card", "window", "separator"]
        let refs = all.flatMap { f in
            f.content.split(separator: "\n").compactMap { line -> String? in
                guard let r = line.range(of: "Surface.") else { return nil }
                let tail = line[r.upperBound...]
                return String(tail.prefix { $0.isLetter || $0.isNumber })
            }
        }
        // ground 在 M0 只定义不接线（挂到滚动容器是 WS-O 的活），故本轮豁免。
        let exempt: Set<String> = ["ground"]
        let dead = Self.unreferencedSurfaceMembers(defined: defined, references: refs)
            .filter { !exempt.contains($0) }
        XCTAssertTrue(dead.isEmpty, "定义了没人用的表面令牌（本轮病因复发）：\(dead)")
    }

    // MARK: 元测试——确认守卫不是假绿

    func test_scannersCatchSyntheticViolations() {
        let dirty = [(path: "Design/Fake.swift",
                      content: "x\n    .shadow(color: .black, radius: 6)\n")]
        XCTAssertEqual(Self.shadowHits(in: dirty).count, 1, "守卫失灵的脏样本")

        let clean = [(path: "Design/Fake.swift",
                      content: "// .shadow(color: .black, radius: 6)\n")]
        XCTAssertTrue(Self.shadowHits(in: clean).isEmpty, "注释被误判")

        XCTAssertEqual(Self.unreferencedSurfaceMembers(defined: ["well", "ink"],
                                                      references: ["Palette.Surface.well"]),
                       ["ink"], "零引用检测漏掉了没被引用的成员")
    }
}
```

Run: `./scripts/locked_build.sh test --filter BorderlessSurfaceGuardTests`
Expected: FAIL —— `test_shadowOnlyInsideFloatingBranch` 报「投影必须全仓唯一，实测 …Glass.swift:137」，且 `well/control/ink` 被判零引用

- [ ] **Step 2: 加 `.floating` case**

```swift
enum GlassLayer: Hashable {
    /// 内容层：**什么都不画**（风格契约 1/2）。
    /// 旧实现填 `.regularMaterial`，实测每层比窗口底暗 6~13 个 RGB 阶（1.05:1），
    /// 叠三层糊成脏灰——「黑黢黢」的成因就是这一条。
    case content
    /// 井：内容层唯一允许的实心底，只给表格/日志/代码块（风格契约 3）。
    case contentInset
    /// 控件/导航层：macOS 26 真玻璃，更早系统实心 + 发丝描边兜底。
    case chrome
    /// 浮层：菜单、进度浮层。**全仓唯一允许投影的层**（风格契约 6）。
    case floating
}
```

- [ ] **Step 3: 重写 `surface(layer:shape:)`**

```swift
extension View {
    @ViewBuilder
    func surface(
        layer: GlassLayer = .content,
        shape: GlassShape = .rounded(Theme.Radius.card)
    ) -> some View {
        switch layer {
        case .content:
            // 无面。不画背景、不描边、不投影——分组交给间距与 `Typo.groupLabel`。
            self
        case .contentInset:
            switch shape {
            case .rounded(let r):
                outlined(shape: RoundedRectangle(cornerRadius: r, style: .continuous),
                         fill: Theme.Palette.Surface.well)
            case .capsule:
                outlined(shape: Capsule(), fill: Theme.Palette.Surface.well)
            }
        case .chrome:
            switch shape {
            case .rounded(let r):
                chromeGlassOrFallback(in: .rect(cornerRadius: r, style: .continuous))
            case .capsule:
                chromeGlassOrFallback(in: Capsule())
            }
        case .floating:
            switch shape {
            case .rounded(let r):
                floatingSurface(in: .rect(cornerRadius: r, style: .continuous))
            case .capsule:
                floatingSurface(in: Capsule())
            }
        }
    }
}
```

- [ ] **Step 4: 三个私有画法helper，投影只进 `floatingSurface`**

```swift
extension View {
    /// 实心 + 发丝描边。**无投影**——这是与旧 `materialLayer` 的关键差别：
    /// 旧版把 `.shadow` 挂在三层公共尾巴上，40 个 `GlassSection` + 29 个 `MetricTile`
    /// + 14 处显式 `surface()` 于是各带一份投影。
    private func outlined<S: InsettableShape>(shape: S, fill: Color) -> some View {
        background {
            shape.fill(fill)
            shape.strokeBorder(Theme.Palette.Surface.separator,
                               lineWidth: Theme.Stroke.hairline)
        }
    }

    @ViewBuilder
    private func chromeGlassOrFallback<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(chromeGlass, in: shape)
        } else {
            outlinedFallback(shape: shape, fill: Theme.Palette.Surface.control)
        }
    }

    @ViewBuilder
    private func floatingSurface<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(chromeGlass, in: shape)
        } else {
            outlinedFallback(shape: shape, fill: Theme.Palette.Surface.control)
                .shadow(color: Theme.Elevation.overlay.shadowColor,
                        radius: Theme.Elevation.overlay.radius,
                        y: Theme.Elevation.overlay.yOffset)
        }
    }

    private func outlinedFallback<S: Shape>(shape: S, fill: Color) -> some View {
        background {
            shape.fill(fill)
            shape.strokeBorder(Theme.Palette.Surface.separator,
                               lineWidth: Theme.Stroke.hairline)
        }
    }
}
```

删除整个旧 `materialLayer(...)`（含 `sheen` / `dimmed` / `.regularMaterial` / `.ultraThinMaterial` 与那条 `.shadow`）。`glassButtonStyle`、`mergedGlassChrome`、`GlassButtonKind`、`FallbackProminentButtonStyle` 保留不动。

- [ ] **Step 5: 跑守卫 + 全量 build**

Run: `./scripts/locked_build.sh test --filter BorderlessSurfaceGuardTests && ./scripts/locked_build.sh build`
Expected: 守卫 PASS（`shadowHits == 1`）；build 可能有页面侧断言失败——本步只要求**编译零 error**

- [ ] **Step 6: Commit**

```bash
git add Sources/TcoderMonitor/Design/Glass.swift Tests/TcoderMonitorTests/BorderlessSurfaceGuardTests.swift
git commit -m "feat(M0-表面): 内容层去面、井收实心、投影从三层公共尾巴移进 .floating"
```

---

### Task 3: 基座组件（MetricTile / ReadoutStrip / GlassSection）

**Files:**
- Modify: `Sources/TcoderMonitor/Design/SharedComponents.swift`
- Modify: `Sources/TcoderMonitor/Design/GlassComponents.swift`

**Interfaces:**
- Consumes: `Theme.Typo.groupLabel`、`Theme.Palette.Surface.ink`、`Theme.Spacing.group`
- Produces: `ReadoutStrip { … }`（`@ViewBuilder` 内容闭包）、`GlassSection` 签名不变、`MetricTile` 初始化签名不变

- [ ] **Step 1: `MetricTile` 去面 + 纯墨 + 禁 tertiary**

`SharedComponents.swift` 的 `MetricTile.body`：

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .themeIcon(.badge)
                        .foregroundStyle(Color.secondary)   // 图标不再吃倾向色
                }
                Text(label)
                    .font(Theme.Typo.groupLabel.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                Text(Self.displayValue(value))
                    .font(Theme.Typo.metricNumber.font)
                    .foregroundStyle(Self.tint(value: value, fallback: tint))
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(Theme.Typo.label.font).foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(Theme.Typo.label.font)
                    .foregroundStyle(.secondary)   // 原 .tertiary：测得值不得用 tertiary
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.tileHeightCompact,
               alignment: .leading)
        // 无 .surface()：tile 不再是一块面（风格契约 1）。
    }
```

并把 `tint` 的默认值从 accent 改成纯墨：

```swift
    init(label: String, value: String?, unit: String? = nil, caption: String? = nil,
         tint: Color = Theme.Palette.Surface.ink, systemImage: String? = nil) { … }

    /// 有值用调用方给的**语义**倾向色，无值一律中性。
    /// 调用方请只传语义色（success/warning/danger）；把 `info`/`accent` 当数据色用是
    /// 风格契约 5 禁止的（旧 `DashboardView.codeScaleCard` 把 182,430 涂成 info 蓝）。
    static func tint(value raw: String?, fallback: Color) -> Color { … 原逻辑不变 … }
```

`displayValue` / `forcesNeutralTint(for:)` 两个纯函数与其既有单测**不动**。

- [ ] **Step 2: 新增 `ReadoutStrip`**

`SharedComponents.swift` 末尾追加。总览的四枚 tile 用它排成一行，列间发丝线，对标活动监视器底栏：

```swift
/// 横向读数带：若干 `MetricTile` 排成一行，列间 0.5pt 分隔线，**无卡面**。
///
/// 存在理由：旧总览是四块 `.contentInset` 灰盒（实测 `#E3E5E7`，比页面底暗 13 阶），
/// 每块自带一份投影。读数带把「分组」这件事交给发丝线与留白，一次去掉 4 个面 + 4 份投影。
struct ReadoutStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewBuilder.buildEither(first: AnyView(
            HStack(alignment: .top, spacing: Theme.Spacing.lg) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        )).frame(maxWidth: .infinity)
    }
}
```

⚠️ 上面这段是**故意写错的占位**——不要照抄。正确实现：

```swift
struct ReadoutStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

分隔线由**调用方**在 tile 之间插 `Divider()`（SwiftUI 的 `Divider` 在 `HStack` 里画竖线）。之所以不在 `ReadoutStrip` 里自动插：各页 tile 数不同，自动插会让"守卫扫不到实际线数"。

- [ ] **Step 3: `GlassSection` 改成无面分组**

`GlassComponents.swift`：

```swift
/// 带标题行的分区——页面里绝大多数分区的默认形态（40 处在用）。
///
/// **它不再是一块面板**（风格契约 1/2）：不画背景、不描边、不投影。
/// 它的全部职责是「一个 `groupLabel` 标题 + 内容 + 组间距」。
/// 旧实现内部套 `GlassCard(layer: .content)` = 一层材质灰 + 一份投影，
/// 40 处调用点于是叠出「整个界面黑黢黢、很脏」的观感。
struct GlassSection<Content: View>: View {
    var title: String
    var subtitle: String?
    var icon: IconName?
    var trailing: AnyView?
    var padding: CGFloat
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, icon: IconName? = nil,
         trailing: AnyView? = nil, padding: CGFloat = 0,
         @ViewBuilder content: () -> Content) { … }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    if let icon {
                        ThemedIcon(icon, role: .cardHeader)
                            .foregroundStyle(.secondary)   // 原 accent.textColor：图标不吃交互色
                    }
                    Text(title).font(Theme.Typo.groupLabel.font)
                        .foregroundStyle(.secondary)
                }
                if let subtitle {
                    Text(subtitle).font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                        .lineSpacing(Theme.Typo.label.lineSpacing)
                }
            }
            Spacer(minLength: Theme.Spacing.xs)
            trailing
        }
    }
}
```

`padding` 默认值从 `Theme.Spacing.cardPadding` 改成 **0**：40 处调用点里绝大多数不显式传，改默认值即一次性去掉卡内 24pt 内边距，页面若要留自己的内边距可显式传。`GlassCard` 保留（`DashboardHero`、`GitInsightsSections` 在用它，它们分别归 WS-O / WS-P 处理）。

- [ ] **Step 4: 双绿检查（允许页面侧断言红，不许编译错）**

Run: `./scripts/locked_build.sh build --build-tests`
Expected: 零 error

- [ ] **Step 5: Commit**

```bash
git add Sources/TcoderMonitor/Design/SharedComponents.swift Sources/TcoderMonitor/Design/GlassComponents.swift
git commit -m "feat(M0-组件): MetricTile 去面改纯墨、新增 ReadoutStrip、GlassSection 改无面分组"
```

---

### Task 4: 表格系统上提进 `Design/`

**Files:**
- Move: `Sources/TcoderMonitor/Views/CodeGit/CodeGitTable.swift` → `Sources/TcoderMonitor/Design/DataTable.swift`
- Modify: `Tests/TcoderMonitorTests/TableHeaderConvergenceTests.swift`

**Interfaces:**
- Produces: `DataGridColumn` / `DataColumns` / `DataTableHeader` / `.tableCell` 符号名**完全不变**，仅文件路径变

- [ ] **Step 1: git mv**

```bash
git mv Sources/TcoderMonitor/Views/CodeGit/CodeGitTable.swift \
       Sources/TcoderMonitor/Design/DataTable.swift
```

- [ ] **Step 2: 改守卫的路径断言**

`TableHeaderConvergenceTests.swift` 三处：

```swift
// 第 133 行
XCTAssertTrue(definitions.first?.file.hasSuffix("Design/DataTable.swift") == true,
              "列头组件必须住在 Design/：它被 6 个目录共用，留在任一页面目录下都等于被该页独占")
// 第 281、294 行的合成元测试样本：把 "Views/CodeGit/CodeGitTable.swift" 一并换成
// "Design/DataTable.swift"，保持「好样本不判违规」这条元测试的语义不变
```

- [ ] **Step 3: 元测试自证不是假绿（关键一步）**

临时造一个重复列头实现，确认守卫会红：

```bash
cat > Sources/TcoderMonitor/Views/Health/_TempDupHeader.swift <<'EOF'
import SwiftUI
struct HealthTableHeader: View { var body: some View { EmptyView() } }
EOF
./scripts/locked_build.sh test --filter TableHeaderConvergenceTests   # 必须 FAIL
rm Sources/TcoderMonitor/Views/Health/_TempDupHeader.swift
./scripts/locked_build.sh test --filter TableHeaderConvergenceTests   # 必须 PASS
```

Expected: 第一次 FAIL（证明守卫活着），删掉后 PASS。
**若第一次就 PASS，说明路径改动把守卫改成了假绿**，停下来修守卫，不要继续。

- [ ] **Step 4: Commit**

```bash
git add -A Sources/TcoderMonitor/Design/DataTable.swift Sources/TcoderMonitor/Views/CodeGit Tests/TcoderMonitorTests/TableHeaderConvergenceTests.swift
git commit -m "refactor(M0-表格): 列系统上提进 Design/（6 目录共用，不该由一个页面目录独占）"
```

---

### Task 5: M0 收尾与基座截图

- [ ] **Step 1: 全量双绿**

Run: `./scripts/locked_build.sh build && ./scripts/locked_build.sh test`
Expected: 双绿。若 `CodeGitRestyleTests` / `PerformanceDesignDebtGuardTests` / `DesignKitTests` 里有钉**旧值**（字号、材质、投影、`cardPadding`）的断言，**由总工更新**——它们属基座契约，不属任何一家页面流。

- [ ] **Step 2: 打包 + 拍基座态九页（浅+深）**

```bash
./scripts/build_app.sh release
SWITCH_MODE=argv CAPTURE_SANDBOX=/tmp/tcoder-m0-light \
  ./scripts/capture_pages_isolated.sh /tmp/m0-pages-light
```

深色需系统切外观（`defaults write -g AppleInterfaceStyle Dark` 属**全机共享状态**，总工执行且事后改回）。

- [ ] **Step 3: 取样确认地面唯一**

```bash
/tmp/pixgrid /tmp/m0-pages-light/总览.png GROUND_A 0.30 0.30 GROUND_B 0.70 0.75
```
Expected: 两点同为单一底色，对比 1.00:1（页面接线由 WS-O 在 M1 完成前，此处允许仍是系统默认底）

- [ ] **Step 4: 打 tag 供三家切树**

```bash
git tag m0-borderless-base
```

---

## Part B — M1 三条并行流

三家**都从 `m0-borderless-base` 切树**，各自 ≤3 子代理，一家之内同一时刻只跑 1 个编译。

```bash
git worktree add /Users/one/Documents/Tcoder/.worktrees/<名> -b ws/<名> m0-borderless-base
```

### 三家的共同工单（写进各自派发 prompt）

对名下**每一页**逐条量这四件事，交付报告里给**改动前后数字**：

1. 该页 `GlassSection` 数与最大字号 → 是否出现「两个 28pt 以上数字争位」或「全是 10–12pt」。每页最多**一个** `heroMetric`；有 `heroMetric` 的页不得再有 `metricNumber` 当第二主角。
2. `.tertiary` 是否落在**测得值**上（路径、时间戳可以；数字不行）→ 全仓当前 42 处，目标：测得值上 0 处。
3. 倾向色是否涂在非语义数据上（当前 `info`/`accent` 36 处）→ 只保留语义状态色。
4. 单组内容量：一组里 > 6 行同类条目 → 拆组或收进可展开区。

外加：
- 主读数改用 `Theme.Palette.Surface.ink`（`.primary` 不够，见 Task 1 Step 4 的理由）。
- 分组间距 `Theme.Spacing.group`(32)；页级段落 `Theme.Spacing.section`(40)；页边距 `Theme.Spacing.pageMargin`(24)。
- 表格/日志/代码块才允许 `.contentInset`（现在是实心井）。
- **不得改 `Design/**` 与 `App/Theme.swift`**。令牌不够用 → 报契约缺口给总工，不许自己加。
- 不得改 `Services/**`、`Models/**`；视图签名冻结；新文件 ≤800 行。
- 拍图：`SWITCH_MODE=argv CAPTURE_SANDBOX=/tmp/tcoder-<流名> ./scripts/capture_pages_isolated.sh /tmp/<流名>-pages`。
- 交回前：`git merge main` → `./scripts/locked_build.sh build && … test` 双绿 → 回执 `./scripts/premerge_check.sh ws/<流名>`。

### Task 6: WS-O 外壳与总览

**Files:** `Views/RootView.swift`、`Views/ProjectDetailView.swift`、`Views/DashboardView.swift`、`Views/Shell/**`、新建 `Tests/TcoderMonitorTests/ShellBorderlessTests.swift`；Obsidian 新建 `80 WS-O 外壳与总览无界化.md`

**必须做到的五件事（spec §3 + §4.1）：**

1. **删掉 `Views/Shell/SectionNav.swift` 的 chip 条**，但 `DetailSection` 枚举、`rawValue` 中文页名、`isReachable(reportAvailable:)` 纯函数**平移保留**（九页取证的 `-selectedDetailSection` 传页靠它，`@AppStorage("selectedDetailSection")` 键名不许改）。
2. 侧栏改两个分组：`Section("项目")` + `Section("分析视图")`（9 行）。`ProjectRow` 删掉 `.surface()` 与 48pt 材质胶囊，行高 30pt，让 `.listStyle(.sidebar)` 画原生选中。视图行用手动选中态（`List(selection:)` 只有一根绑定，两个选择轴）：选中 = accent 淡底胶囊 + `.primary`；未选中 = 纯文字。
3. `ProjectDetailView` 挂 `Theme.Palette.Surface.ground` 到滚动容器；头部项目名 `pageTitle`(20)，路径/分析时间一行 `label`(11)；不再画 chip 条与那条 `Divider()`。
4. `DashboardView`：四枚 `MetricTile` → 一条 `ReadoutStrip`；`codeScaleCard` 的 `182,430` 从 `info` 蓝改 `Surface.ink` 并可升 `heroMetric`(56)；`代码规模` 一张卡里的「大数 + 5 条占比 + 3 个 StatLine + 覆盖率 4 行」**拆成分组**，覆盖率口径说明降为 10pt 脚注；主区块间距 `md`(16) → `group`(32)。
5. `ProgressOverlay` 改 `.floating`（它是全仓唯一该有投影的东西）。

**红线**：`#37`/`#38` 的诚实性文案（口径说明、含测试代码对比、报告生成时间、`generationSummaryText`）**一字不删**，只许降排版层级。

**验收**：`ShellBorderlessTests` 断言 ① `SectionNavBar` 符号全仓零引用 ② `DetailSection.isReachable` 仍有测试钉住 ③ 总览 `.tertiary` 落在测得值上 = 0 ④ 总览最大字号元素是全页最暗像素（截图取样）。

### Task 7: WS-P 代码与 Git 五页

**Files:** `Views/Code/**`、`Views/Git/**`、`Views/Dependencies/**`、`Views/CodeGit/**`（`CodeGitTable.swift` 已上提，此处只剩页面）、新建 `Tests/TcoderMonitorTests/CodeGitBorderlessTests.swift`；Obsidian 新建 `82 WS-P 代码与Git五页无界化.md`

**特有事项**：`Views/CodeGit/CodeGitDesignKit.swift` 有 2 处裸 `Font.system(size:)`（全仓仅存的两处）→ 收进 `Theme.Typo`，若缺档报总工。Git 页的 merge 提交口径说明（"共 N 次提交（含 M 次合并）· 作者与代码行统计基于 K 次非合并提交"）与 `historyTruncated` 窗口标注属功能性诚实修正，**不得删**。

### Task 8: WS-W 性能·日志·评分三页

**Files:** `Views/Performance/**`、`Views/Logs/**`、`Views/Health/**`、`Views/PerfLogs/**`、新建 `Tests/TcoderMonitorTests/PerfLogsBorderlessTests.swift`；Obsidian 新建 `84 WS-W 性能日志评分无界化.md`

**特有事项**：性能页是**杀手功能**，实时曲线不得因去面而丢可读性——曲线用灰阶主线 + 语义色点缀（风格契约 5），`Theme.Chart` 多色板只在需要区分类别时用。`PerfLogs/ChartChrome.swift` 的坐标轴已走 `Surface.separator`，保持。健康页的 `score == nil` 必须仍走 neutral/空心，不落 danger。

---

## Part C — M2 集成

### Task 9: 合入三家

- [ ] 按 `WS-O → WS-P → WS-W` 顺序（外壳先落，页面后落，减少视觉判断干扰）：

```bash
./scripts/premerge_check.sh ws/o-borderless   # 双绿才 merge
git merge --no-ff ws/o-borderless
```

任一失败即拒合，退回该流。**不得 `--no-verify`、不得跳过 `premerge_check.sh`。**

- [ ] 三家合完跑全量：`./scripts/locked_build.sh build && ./scripts/locked_build.sh test`

### Task 10: 最终取证与判据反查

- [ ] `./scripts/build_app.sh release`，确认 `verify_provenance.sh` 过（产物 == HEAD）
- [ ] 九页 × 浅深 = 18 张：`SWITCH_MODE=argv ./scripts/capture_pages_isolated.sh /tmp/final-pages-light`
- [ ] 像素反查（spec §6.2）：同页非井非文字区域任意两点对比 = 1.00:1；不存在比页面底更暗的卡面；全页最暗像素落在最大字号元素上；墨/底 ≥ 15:1
- [ ] 机械反查（spec §6.1 表）：`shadowHits == 1`；`Surface.*` 零引用成员为空（含 `ground`，此时豁免该撤）；`Spacing.section` 引用数 > 0；大字档 `Typo` 引用占比 ≥ 12%
- [ ] 更新 `docs/九页实拍读数.md`（取证基准挂到最终交付头）与 `README.md`
- [ ] 撤掉 `BorderlessSurfaceGuardTests` 里 `ground` 的 `exempt`，确认全绿后提交

### Task 11: 清工作树

- [ ] 每棵判据 `git status --porcelain` 为空 **且** `git rev-list --count main..ws/<名>` 为 0，才 `git worktree remove`
- [ ] 删分支一律 `git branch -d`（未合并会自己拒绝，不用 `-D`）
- [ ] 反向复核：仍存在的 `ws/*` 分支里凡 `ahead > 0` 的，**它的树必须还在**
- [ ] `git worktree prune`；`git tag -d m0-borderless-base`

---

## 自检结论

**1. Spec 覆盖**：风格契约 1–8 → Task 1/2/3（1/2/3/4/6/8 的取值与画法）、Task 6（7 的导航）、Task 1 Step 5（8 的节奏）；根因 ①–⑤ → Task 2 Step 1/3、Task 3、Task 6；§6.1 机械判据 → Task 2 Step 1 + Task 10；§6.2 像素判据 → Task 5/6/10；§7 风险 2（既有测试大面积红）→ Task 5 Step 1 明确归总工；风险 3（56pt 撑破窄列）→ Part B 共同工单第 1 条。**无遗漏。**

**2. 占位符**：Task 3 Step 2 故意放了一段错代码并标注"不要照抄"——这是**有意的反面样本**（该处 `ViewBuilder.buildEither` 是我起草时的真实错误，留着是为了让执行者不去"顺手优化"成那个形状）。已显式给出正确实现。其余无占位符。

**3. 类型一致性**：`Surface.ground/well/control/ink` 在 Task 1 定义、Task 2 引用 `well/control`、Task 3 引用 `ink`、Task 6 引用 `ground`，命名一致；`Typo.groupLabel` 在 Task 1 定义、Task 3 消费；`ReadoutStrip` 在 Task 3 定义、Task 6 消费；`GlassLayer.floating` 在 Task 2 定义、Task 6 消费。`Theme.Spacing.group` 与既有 `Theme.Spacing` 无同名冲突（原为 `lg`/`xl`/`xxl`/`section`）。

**4. 已核实的依赖事实**：`DualColor.color`（`Design/ColorToken.swift` 的 `DualColor.color`）内部是
`NSColor(name: nil) { appearance in … }`，**随系统外观自动切换**。所以 Task 1 Step 4 的四个地面令牌
直接写 `DualColor(lightHex:darkHex:).color` 即可，不需要再包一层动态色。
