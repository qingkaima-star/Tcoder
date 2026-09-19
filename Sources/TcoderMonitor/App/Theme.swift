import SwiftUI

/// Chief-engineer owned design system. Every workstream renders through these tokens
/// and components so parallel UI work still looks like one product.
enum Theme {
    static let accent = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let healthy = Color(red: 0.19, green: 0.72, blue: 0.30)
    static let caution = Color(red: 0.91, green: 0.64, blue: 0.24)
    static let danger = Color(red: 0.89, green: 0.35, blue: 0.23)
    static let critical = Color(red: 0.70, green: 0.15, blue: 0.12)
    static let neutral = Color(red: 0.56, green: 0.56, blue: 0.58)

    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let subtleBackground = Color(nsColor: .windowBackgroundColor)

    static let gridLine = Color.primary.opacity(0.08)

    static func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .none: return neutral
        case .low: return healthy
        case .medium: return caution
        case .high: return danger
        case .critical: return critical
        }
    }

    static func color(forScore score: Int) -> Color {
        switch score {
        case 85...: return healthy
        case 70..<85: return accent
        case 55..<70: return caution
        default: return danger
        }
    }

    static let monoSmall = Font.system(.caption, design: .monospaced)
    static let monoBody = Font.system(.body, design: .monospaced)
    static let metricNumber = Font.system(size: 26, weight: .semibold, design: .rounded)
    static let heroNumber = Font.system(size: 48, weight: .bold, design: .rounded)
}

enum IconName: String {
    case code = "curlybraces"
    case git = "arrow.triangle.branch"
    case people = "person.2.fill"
    case pulse = "waveform.path.ecg"
    case logs = "doc.text.magnifyingglass"
    case package = "shippingbox.fill"
    case health = "checkmark.shield.fill"
    case dashboard = "square.grid.2x2.fill"
}

// MARK: - Reusable components

struct SectionCard<Content: View>: View {
    var title: String
    var subtitle: String?
    var icon: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let icon {
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        Text(title).font(.headline)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(14)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.gridLine, lineWidth: 1)
        )
    }
}

struct MetricTile: View {
    var label: String
    var value: String
    var unit: String?
    var caption: String?
    var tint: Color = Theme.accent
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.metricNumber)
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.gridLine, lineWidth: 1)
        )
    }
}

struct RiskBadge: View {
    var risk: RiskLevel
    var showIcon: Bool = true

    var body: some View {
        HStack(spacing: 3) {
            if showIcon {
                Image(systemName: risk == .none ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            Text("风险 \(risk.rawValue)")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.color(for: risk))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.color(for: risk).opacity(0.14), in: Capsule())
    }
}

struct SeverityBadge: View {
    var severity: LogSeverity

    var body: some View {
        Text(severity.rawValue)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(hex: severity.colorHex))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(hex: severity.colorHex).opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}

struct MiniBarGauge: View {
    var fraction: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.gridLine)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

struct EmptyStateView: View {
    var icon: String = "tray"
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(24)
    }
}

struct ProgressOverlay: View {
    var phase: AnalysisPhase
    var projectName: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(projectName) · \(phase.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }
}

extension AnalysisPhase {
    var label: String {
        switch self {
        case .idle: return "空闲"
        case .code: return "正在扫描代码规模…"
        case .git: return "正在分析 Git 历史…"
        case .logs: return "正在解析错误日志…"
        case .dependencies: return "正在检查依赖…"
        case .health: return "正在计算健康评分…"
        case .finished: return "分析完成"
        case .failed: return "分析失败"
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value & 0xFF0000) >> 16) / 255
        let green = Double((value & 0x00FF00) >> 8) / 255
        let blue = Double(value & 0x0000FF) / 255
        self = Color(red: red, green: green, blue: blue)
    }
}

extension Double {
    var asPercentString: String { NumberFormat.percent(self, precision: 1) }
}
