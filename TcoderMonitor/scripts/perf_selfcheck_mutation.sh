# selfcheck 反例分块：**变异类臂自己的反证**（这一族只管一件事——
# "把尺子改坏要求它变红"这类反向格，它自己有没有被反证过）。
# 来路：卷十二 §185 把 selfcheck 第 8 项 `migration` 那一格升级成三道关之后，
# 两个反例的造法只活在 `/tmp/mig_harness.sh` 里 ⇒ 门禁只跑得到正控制那一格
# （第 20 类：没读者的机制不算落地；第 46 类：空结果伪装成通过）。
# 这一项就把那两格搬进门禁：**假变异不许冒充"有牙"**。
# shellcheck shell=bash

# 第 8 项与第 78 项**共用同一份夹具**（两件事各写一份必然漂移，本仓为"两份副本两个数"记过好几回）。
migration_fixture_build() {  # migration_fixture_build <夹具树>
  local fake="$1"
  mkdir -p "$fake/Tests/TcoderMonitorTests" "$fake/Sources/TcoderMonitor/Views"
  cat > "$fake/Tests/TcoderMonitorTests/PerfInvalidationRatchetTests.swift" <<'SWIFT'
    static let coarsePattern = #"monitor\s*\.\s*(latestSnapshot|history)\b"#
    static let finePattern = #"monitor\s*\.\s*(cpu|pulse)\s*\.\s*value\b"#
    static let coarseCallSiteCeiling = 7
    private static let consumerDirectories = ["Sources/TcoderMonitor/Views"]
    static let nothingThatReadsThis = 1
SWIFT
  cat > "$fake/Sources/TcoderMonitor/Views/Fake.swift" <<'SWIFT'
  // 文档注释里提到 monitor.latestSnapshot 不算调用点（与守卫同一条豁免）
  Text(monitor.cpu.value.title)
  Chart(monitor.history)
SWIFT
}

selfcheck_mutation_teeth_are_proved() {  # 78) 反例自己也要被反证：变异落空与惰性变异都必须出声（§186）
  local out="$1" fake mig spoke bad=0
  # 三格都在子 shell 里跑（为的是抓到它们各自印了什么）；**出声由本项自己在父 shell 里做**，
  # 否则 `item` 那层"每项必须出声"的兜底会被绕过。
  fake="$out/mutation-real"; migration_fixture_build "$fake"
  mig=$(python3 "$TRACE_REPORT" migration --module-root "$fake" 2>&1)
  spoke=$(migration_rejects_a_renamed_ruler "$fake" "$mig" 2>&1)
  printf '%s' "$spoke" | grep -q "拒绝退回手抄正则" \
    || { bad=$((bad + 1)); fail "78 正控制红：真变异那一格没走绿，说明三道关本身坏了：$(printf '%s' "$spoke" | head -2)"; }

  fake="$out/mutation-noop"; migration_fixture_build "$fake"
  mig=$(python3 "$TRACE_REPORT" migration --module-root "$fake" 2>&1)
  spoke=$(migration_rejects_a_renamed_ruler "$fake" "$mig" \
            's/static let nothingReadsThisAtAll/static let renamedAnyway/' 2>&1)
  printf '%s' "$spoke" | grep -q "变异没改进文件" \
    || { bad=$((bad + 1)); fail "78 sed 落空那一格没出声 ⇒ 假变异仍能冒充有牙（macOS 的 sed 打不中是静默的）"; }

  fake="$out/mutation-inert"; migration_fixture_build "$fake"
  mig=$(python3 "$TRACE_REPORT" migration --module-root "$fake" 2>&1)
  spoke=$(migration_rejects_a_renamed_ruler "$fake" "$mig" \
            's/static let nothingThatReadsThis/static let nothingThatReadsThisRenamed/' 2>&1)
  printf '%s' "$spoke" | grep -q "逐字相同" \
    || { bad=$((bad + 1)); fail "78 惰性变异那一格没出声 ⇒ 改了报告不读的那一行，红与这条判据无关，仍会被算作牙"; }

  [ "$bad" = "0" ] && ok "变异臂的反证三格齐：正控制走绿、sed 落空要喊、改了报告不读的那一行也要喊（78）"
}

selfcheck_arms_are_all_wired() {  # 79) 每把臂都必须真的被调用：盘上块 ↔ `_part` 名单 ↔ `item` 调用，三张表两头对齐（§188）
  # 为什么这条比"文件 ≤400 行"那把门更值钱：拆文件的动机就是"再加一臂会撞红"，而**拆的过程本身
  # 最容易掉臂**——函数搬走了、`item` 那行没跟过去，或 `_part` 名单漏了新块。这两种都**不会报错**：
  # 前者是"定义了没人调"（臂静默消失），后者是"名单里有个不存在的块"（source 少一块，项数悄悄少）。
  # 本仓为"空结果伪装成通过"记过第 46 类；这条就是它在这块的专职读者。
  local out="$1" listed defined called orphan ghost block stem bad=0
  listed=$(sed -n 's/^for _part in \(.*\); do$/\1/p' scripts/perf_selfcheck.sh)
  [ -n "$listed" ] \
    || { fail "79 取不到 _part 名单（宿主那一行的形状变了）⇒ 这条普查自己失效，先修它"; return; }

  # ① 盘上的块 ↔ 名单（两个方向）
  for block in scripts/perf_selfcheck_*.sh; do
    stem=${block#scripts/perf_selfcheck_}; stem=${stem%.sh}
    case " $listed " in *" $stem "*) ;; *) orphan="$orphan$stem " ;; esac
  done
  for stem in $listed; do
    [ -f "scripts/perf_selfcheck_${stem}.sh" ] || ghost="$ghost$stem "
  done

  # ② 定义了的臂 ↔ 真的被调用了（`item x` 与被别的臂直接调都算数；只认 `item` 会误报三个假孤儿——
  #    `selfcheck_weight_ruler` 那三个帮手就是被它自己调的，第一版我就被这条骗过一次）
  defined=$(grep -h '^selfcheck_[a-z_0-9]*()' scripts/perf_selfcheck*.sh \
            | sed -E 's/^(selfcheck_[a-z_0-9]+\(\).*)$/\1/' | cut -d'(' -f1 | sort -u)
  called=$(grep -hE '^[[:space:]]+(item[[:space:]]+)?selfcheck_[a-z_0-9]+[[:space:]]' scripts/perf_selfcheck*.sh \
           | sed -E 's/^[[:space:]]+(item[[:space:]]+)?(selfcheck_[a-z_0-9]+)[[:space:]].*/\2/' | sort -u)

  [ -z "$orphan" ] || { bad=$((bad + 1)); fail "79 盘上有这块、_part 名单里没有 ⇒ 它里面的臂**永远不会被跑**：$orphan"; }
  [ -z "$ghost" ] || { bad=$((bad + 1)); fail "79 名单里有这个名字、盘上没有这块 ⇒ source 少一块而项数悄悄少：$ghost"; }
  local unwired
  unwired=$(comm -23 <(printf '%s\n' "$defined") <(printf '%s\n' "$called") | tr '\n' ' ')
  [ -z "${unwired// /}" ] || { bad=$((bad + 1)); fail "79 这些臂定义了却没有任何调用点 ⇒ 它是死代码，不是判据：$unwired"; }

  [ "$bad" = "0" ] && ok "selfcheck 三张表对齐：盘上 $(printf '%s\n' "$listed" | wc -w | tr -d ' ') 块全在名单里、" \
     "「_part」名单没有幽灵块、定义到的 $(printf '%s\n' "$defined" | wc -l | tr -d ' ') 把臂全有调用点（79）"
}
