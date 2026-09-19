import Foundation
@testable import TcoderMonitor

// WS-F 夹具树的正文素材（Java/Go/Swift/Rust/Python/TypeScript 源码与两份日志）。
// 逐行原样搬自 ManifestLabFixtureTests.swift；`private` 降为 internal，
// 才能被 ManifestLabTree+*.swift 里各段写入函数调用（WS-V 机械拆分）。
extension LabTree {
    // MARK: - 正文素材

    /// 恰好 430 行：`routeOrder` 手写圈复杂度 17（1 基准 + if/&&/foreach/if/||/while/4×case/2×if/2×catch/2×三元）。
    static func orderOrchestrator() -> [String] {
        var lines = [
            "package com.acme.orders;",
            "",
            "import java.util.HashMap;",
            "import java.util.List;",
            "import java.util.Map;",
            "",
            "/**",
            " * 订单编排器：夹具里刻意写到 430 行，用来验证巨大文件榜与热点函数榜。",
            " */",
            "public class OrderOrchestrator {",
            "",
            "    private final Map<String, Integer> counters = new HashMap<>();",
            "    private int attempt = 0;",
            "",
            "    // TODO: 计数器要接监控上报，不能只留在实例字段里。",
            "",
            "    public String routeOrder(Order order, List<String> lanes) {",
            "        int score = order.totalScore();",
            "        // TODO: 这段决策树应该改成策略表，而不是继续往里堆分支。",
            "        if (score > 90 && attempt == 0) {",
            "            return \"vip\";",
            "        }",
            "        for (String lane : lanes) {",
            "            if (lane.isEmpty() || score < 0) {",
            "                continue;",
            "            }",
            "            while (attempt > 3) {",
            "                attempt = attempt - 1;",
            "            }",
            "        }",
            "        switch (order.state()) {",
            "            case NEW:",
            "            case DRAFT:",
            "                score = score + 5;",
            "                break;",
            "            case PAID:",
            "                if (score > 20) {",
            "                    score = score * 2;",
            "                }",
            "                break;",
            "            case SHIPPED:",
            "                score = score > 0 ? score : 1;",
            "                break;",
            "            default:",
            "                score = -1;",
            "        }",
            "        try {",
            "            validate(order);",
            "        } catch (IllegalStateException ex) {",
            "            // FIXME: 这里吞掉了状态机冲突，真实实现必须往上报。",
            "            score = 0;",
            "        } catch (IllegalArgumentException ex) {",
            "            score = -2;",
            "        }",
            "        if (score < 0) {",
            "            return \"rejected\";",
            "        }",
            "        return score % 2 == 0 ? \"even\" : \"odd\";",
            "    }",
            "",
            "    private void validate(Order order) {",
            "        // TODO: 校验规则应当整表接过来，而不是继续往这里加 if。",
            "        if (order.id() <= 0) {",
            "            throw new IllegalArgumentException(\"bad id\");",
            "        }",
            "    }",
            "",
        ]
        pad(&lines, toTotal: 430)
        lines.append("}")
        return lines
    }

    /// 恰好 1600 行，越过 criticalFileLines(1500)，并带 NPE 隐患。
    static func userService() -> [String] {
        var lines = [
            "package com.acme.orders;",
            "",
            "import java.util.ArrayList;",
            "import java.util.List;",
            "",
            "/**",
            " * 用户服务：夹具里刻意写成 1600 行，对应巨大文件榜单第一名。",
            " */",
            "public class UserService {",
            "",
            "    private final List<String> auditTrail = new ArrayList<>();",
            "    private Price lastPrice;",
            "    private String currentLane;",
            "",
            "    public String loadPrice(String lane) {",
            "        // TODO: 这里应当从价格中心取，而不是缓存字段直接解引用。",
            "        this.currentLane = lane;",
            "        if (lane == null) {",
            "            return \"missing\";",
            "        }",
            "        String body = lookup(lane);",
            "        return body.trim().toUpperCase();",
            "    }",
            "",
            "    public int charge(String lane, int amount) {",
            "        Price price = lastPrice;",
            "        try {",
            "            int scaled = price.getTotal() * amount;",
            "            auditTrail.add(lane);",
            "            return scaled;",
            "        } catch (RuntimeException ex) {",
            "            // java.lang.NullPointerException 的真实来源：lastPrice 在冷启动时是 null。",
            "            return -1;",
            "        }",
            "    }",
            "",
            "    public String currentLane() {",
            "        // TODO: 审计轨迹要按租户分片，这里先取第一条凑数。",
            "        for (String entry : auditTrail) {",
            "            if (entry.length() > 0) {",
            "                return entry;",
            "            }",
            "        }",
            "        return \"none\";",
            "    }",
            "",
            "    private String lookup(String lane) {",
            "        // FIXME: 桩数据，真实实现要走 RPC。",
            "        if (lane.equals(\"domestic\")) {",
            "            return \" 12 \";",
            "        }",
            "        while (auditTrail.size() > 512) {",
            "            auditTrail.remove(0);",
            "        }",
            "        return \" 40 \";",
            "    }",
            "",
        ]
        pad(&lines, toTotal: 1600)
        lines.append("}")
        return lines
    }

    /// 两个文件各一份、逐行相同的 16 行块（从 `LIMITS` 到 `clampLimit` 结束）。
    static func clonedRules(className: String) -> [String] {
        var lines = [
            "package com.acme.orders;",
            "",
            "import java.util.HashMap;",
            "import java.util.Map;",
            "",
            "public class " + className + " {",
            "",
            "    private static final Map<String, Integer> LIMITS = new HashMap<>();",
            "",
            "    static {",
            "        LIMITS.put(\"domestic\", 40);",
            "        LIMITS.put(\"cross_border\", 120);",
            "        LIMITS.put(\"pickup\", 8);",
            "    }",
            "",
            "    public int clampLimit(String lane, int requested) {",
            "        Integer ceiling = LIMITS.get(lane);",
            "        if (ceiling == null) {",
            "            return requested;",
            "        }",
            "        if (requested < 0) {",
            "            return 0;",
            "        }",
            "        return Math.min(ceiling.intValue(), requested);",
            "    }",
            "",
        ]
        pad(&lines, toTotal: 120)
        lines.append("}")
        return lines
    }

    static func orderModel() -> [String] {
        [
            "package com.acme.orders;",
            "",
            "import java.util.Collections;",
            "import java.util.List;",
            "",
            "public final class Order {",
            "",
            "    public enum State { NEW, DRAFT, PAID, SHIPPED }",
            "",
            "    private final long id;",
            "    private final int score;",
            "    private final State state;",
            "    private final List<String> lanes;",
            "",
            "    public Order(long id, int score, State state, List<String> lanes) {",
            "        this.id = id;",
            "        this.score = score;",
            "        this.state = state;",
            "        this.lanes = lanes;",
            "    }",
            "",
            "    public long id() { return id; }",
            "",
            "    public int totalScore() { return score; }",
            "",
            "    public State state() { return state; }",
            "",
            "    public List<String> items() { return Collections.unmodifiableList(lanes); }",
            "}",
            "",
        ]
    }

    /// 把文件撑到指定总行数。
    ///
    /// 刻意用**注释行**撑长度，不用重复代码：归一化会把标识符折成 `I`、数字折成 `N`，
    /// 于是「同一形状的填充方法」写 100 份就是 100 份 type-2 克隆（实测撑出过 58% 的
    /// 重复率，把真正要验的那一处拷贝粘贴彻底淹没）。注释行既不进重复指纹通道也不进
    /// `codeLines` 分母，只贡献 `totalLineCount` —— 正好用来验「巨大文件」榜单。
    static func pad(_ lines: inout [String], toTotal target: Int) {
        let notes = [
            "    // 归档说明：这一段是历史行为记录，只描述现状，不代表规划。",
            "    // 复盘：出问题的分支都已经有用例覆盖，保留原文便于对照。",
            "    // 迁移备忘：等价的策略表条目已在库存脚本里，勿在此处再写一份。",
            "    // 交接说明：改这里之前先看同目录的 README 与订单域名词表。",
            "    // 值班记录：夜间告警曾指向同一段逻辑，处置步骤见运维手册。",
        ]
        var index = 0
        while lines.count + 1 < target {
            lines.append(notes[index % notes.count])
            index += 1
        }
    }

    // MARK: 日志正文（@Dn@ = n 天前）

    /// 真值：ERROR 5、WARN 3、FATAL 2、INFO 4、DEBUG 2、顶层异常头 4、帧与 Caused by 9，共 29 行。
    static func errorLog() -> String {
        realTabs(#"""
        @D2@ 07:15:04,201 INFO  [orders-service] c.a.o.Bootstrap - inventory warm-up finished in 412ms
        @D2@ 07:15:19,884 ERROR [orders-service] c.a.o.PayClient - HTTP 调用超时 url=https://pay.acme.example/v1/charge cost=30006ms
        java.net.SocketTimeoutException: Read timed out
        \tat com.acme.orders.PayClient.post(PayClient.java:88)
        @D2@ 09:02:41,500 WARN  [orders-service] c.a.o.Retry - 第 1 次重试 lane=domestic
        @D2@ 09:41:07,120 ERROR [orders-service] c.a.o.OrderService - 处理订单失败 orderId=77001 user=4f9a2b7c-1d3e-4f5a-9b8c-7d6e5f4a3b2c
        java.lang.NullPointerException: Cannot invoke "com.acme.orders.Price.getTotal()" because "price" is null
        \tat com.acme.orders.OrderService.pay(OrderService.java:123)
        \tat com.acme.orders.OrderController.submit(OrderController.java:56)
        Caused by: java.lang.IllegalStateException: price cache miss for sku 991-ABC
        \tat com.acme.orders.PriceCache.lookup(PriceCache.java:44)
        @D2@ 09:41:09,001 DEBUG [orders-service] c.a.o.PriceCache - cache size 2048 entries
        @D1@ 08:03:11,640 ERROR [orders-service] c.a.o.OrderService - 处理订单失败 orderId=77188 user=9a8b7c6d-5e4f-4a3b-8c7d-6e5f4a3b2c1d
        java.lang.NullPointerException: Cannot invoke "com.acme.orders.Price.getTotal()" because "price" is null
        \tat com.acme.orders.OrderService.pay(OrderService.java:123)
        \tat com.acme.orders.OrderController.submit(OrderController.java:56)
        @D1@ 08:03:12,010 WARN  [orders-service] c.a.o.Retry - 第 2 次重试 lane=cross_border
        @D1@ 11:22:55,300 INFO  [orders-service] c.a.o.Health - liveness probe ok
        @D1@ 19:40:02,777 FATAL [orders-service] c.a.o.Bootstrap - 关键服务不可用，退出
        @D0@ 06:30:00,100 INFO  [orders-service] c.a.o.Health - liveness probe ok
        @D0@ 06:31:47,902 ERROR [orders-service] c.a.o.StockLedger - 库存扣减失败 sku=INV-2201 warehouse=WH3
        @D0@ 06:31:48,001 WARN  [orders-service] c.a.o.StockLedger - 已进入人工核对队列
        @D0@ 06:40:12,345 DEBUG [orders-service] c.a.o.OrderMetrics - counter flush 128 series
        @D0@ 06:41:59,999 ERROR [orders-service] c.a.o.OrderService - 处理订单失败 orderId=77205 user=11223344-5566-4778-8899-aabbccddeeff
        java.lang.NullPointerException: Cannot invoke "com.acme.orders.Price.getTotal()" because "price" is null
        \tat com.acme.orders.OrderService.pay(OrderService.java:123)
        \tat com.acme.orders.OrderController.submit(OrderController.java:56)
        @D0@ 07:00:00,500 INFO  [orders-service] c.a.o.Report - 日报生成完成
        @D0@ 07:02:11,777 FATAL [orders-service] c.a.o.Bootstrap - 数据库连接池耗尽，退出

        """#)
    }

    /// 累积型崩溃日志：刻意不含 `Incident Identifier`，也不含 `Exception Type` + `Thread `，
    /// 于是每个 `Fatal error` 锚点各算一次崩溃，共 3 次。
    static func crashLog() -> String {
        realTabs(#"""
        @D2@ 10:11:00.000 Fatal error: Unexpectedly found nil while unwrapping an Optional value in Cache.flush
        @D1@ 21:04:00.000 Fatal error: Unexpectedly found nil while unwrapping an Optional value in Cache.flush
        @D0@ 05:55:00.000 Fatal error: Index out of range in Ledger.trim

        """#)
    }

    /// 把「反斜杠 + t」换成真制表符：Java 堆栈帧的常规形态就是行首一个真 tab。
    static func realTabs(_ text: String) -> String {
        text.replacingOccurrences(of: "\\t", with: "\t")
    }

}
