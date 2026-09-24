#!/usr/bin/env bash
# ============================================================================
# 第 11 章动手实验：把每一种「自愈」都亲眼看一遍
#
# 实验列表：
#   1. 容器重启 vs Pod 重建（Pod IP 变不变、RESTARTS 归不归零）
#   2. readiness 失败：只摘流量，不重启容器（对比强化）
#   3. CrashLoopBackOff 的指数退避（观察 RESTARTS 增长越来越慢）
#   4. 慢启动 + liveness 太急 → 死循环；加 startupProbe 后修复
#   5. 三种探针职责分离的「正确姿势」参考对象
#   6. 清理
#
# 说明：本实验会创建「故意坏掉」的 Pod，只在实验集群运行。
#
# 用法：
#   bash cases/cloudnote/tools/probes-lab.sh            # 跑全部
#   bash cases/cloudnote/tools/probes-lab.sh 1 2 4      # 只跑指定步骤
#   bash cases/cloudnote/tools/probes-lab.sh --cleanup  # 只做清理
# ============================================================================
set -uo pipefail

NS="cloudnote"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
DEPLOY="api"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
cmd()  { printf '\033[2m  $ %s\033[0m\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  %s\033[0m\n' "$1"; }

cleanup() {
  bold "清理实验资源"
  kubectl delete -f "$CASE_DIR/70-probes-demo.yaml" --ignore-not-found=true --wait=false >/dev/null 2>&1
  kubectl delete pod crash-demo slow-start-broken slow-start-fixed probe-compare -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  # 恢复 api 的 readiness 路径，避免影响后续实验
  kubectl patch deployment "$DEPLOY" -n "$NS" --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}
  ]' >/dev/null 2>&1
  ok "已清理演示 Pod，并把 api 的 readiness 路径恢复为 /。"
}

CLEANUP_ONLY=0
STEPS=()
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP_ONLY=1 ;;
    1|2|3|4|5|6) STEPS+=("$arg") ;;
    *) printf '未知参数：%s\n' "$arg"; exit 1 ;;
  esac
done

if [ "$CLEANUP_ONLY" = "1" ]; then cleanup; exit 0; fi
[ "${#STEPS[@]}" -eq 0 ] && STEPS=(1 2 3 4 5 6)

command -v kubectl >/dev/null 2>&1 || { printf '找不到 kubectl。\n'; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { printf '连不上集群。请先按第 1 章【积木 1-10】起一个集群。\n'; exit 1; }

printf '\n\033[1;33m本实验会在 %s 命名空间创建若干「故意异常」的演示 Pod。\033[0m\n' "$NS"
printf '继续？(y/N) '
read -r answer
case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac

want() { for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

ensure_api() {
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  kubectl get deployment "$DEPLOY" -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/20-api-deployment.yaml" >/dev/null
  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=180s >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
if want 1; then
  bold "实验一：容器重启 vs Pod 重建（Pod IP 会变吗？）"
  rule
  ensure_api
  printf '\n'
  info "① 初始状态："
  kubectl get pods -n "$NS" -l app="$DEPLOY" -o custom-columns='NAME:.metadata.name,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount' | sed 's/^/    /'
  POD=$(kubectl get pods -n "$NS" -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}')
  OLD_IP=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.podIP}')
  printf '\n'
  info "② 进入 $POD 把主进程干掉（kill 1），模拟「容器进程崩溃」"
  kubectl exec "$POD" -n "$NS" -- sh -c 'kill 1' >/dev/null 2>&1 || true
  info "   等待 kubelet 重启容器……"
  sleep 12
  printf '\n'
  info "③ 容器级重启后："
  kubectl get pods -n "$NS" -l app="$DEPLOY" -o custom-columns='NAME:.metadata.name,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount' | sed 's/^/    /'
  NEW_IP=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.podIP}' 2>/dev/null)
  printf '\n'
  if [ "$OLD_IP" = "$NEW_IP" ]; then
    ok "Pod IP 没变（$OLD_IP）—— 因为只有容器被重启，Pod 还是同一个"
    info "这就是第 2 章 pause 容器的功劳：Pod 的网络命名空间被 pause 容器持有，与业务容器解耦。"
  else
    info "Pod IP 从 $OLD_IP 变成了 ${NEW_IP:-（Pod 已被重建）}"
  fi
  printf '\n'
  info "④ 现在删掉整个 Pod，模拟「Pod 级故障」"
  cmd "kubectl delete pod $POD -n $NS"
  kubectl delete pod "$POD" -n "$NS" --wait=false >/dev/null 2>&1
  sleep 12
  printf '\n'
  info "⑤ Pod 重建后："
  kubectl get pods -n "$NS" -l app="$DEPLOY" -o custom-columns='NAME:.metadata.name,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount' | sed 's/^/    /'
  printf '\n'
  printf '    %-28s %-24s %s\n' "操作" "Pod IP" "RESTARTS"
  printf '    %s\n' "------------------------------------------------------------------"
  printf '    %-28s %-24s %s\n' "容器被重启" "不变" "+1"
  printf '    %-28s %-24s %s\n' "Pod 被重建" "变了" "归 0"
  printf '\n'
  ok "结论：RESTARTS 只统计「容器级重启」。Pod 重建后它会清零 —— 所以它不能用来判断 Pod 稳不稳定。"
fi

# ---------------------------------------------------------------------------
if want 2; then
  bold "实验二：readiness 失败只摘流量，不重启容器"
  rule
  ensure_api
  kubectl get svc "$DEPLOY" -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/22-api-service.yaml" >/dev/null
  printf '\n'
  info "① 把 readiness 探针指向一个不存在的路径（模拟「依赖抖动导致不健康」）"
  kubectl patch deployment "$DEPLOY" -n "$NS" --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/does-not-exist"}
  ]' >/dev/null 2>&1
  info "   等待探针连续失败（约 30 秒）……"
  sleep 30
  printf '\n'
  info "② Pod 状态（READY 应变 0/1，但 STATUS 仍是 Running）："
  kubectl get pods -n "$NS" -l app="$DEPLOY" | sed 's/^/    /'
  printf '\n'
  info "③ RESTARTS 有没有增加？（关键：应该完全没变）"
  kubectl get pods -n "$NS" -l app="$DEPLOY" -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount' | sed 's/^/    /'
  printf '\n'
  info "④ Service 后端列表（应变空）："
  kubectl get endpoints "$DEPLOY" -n "$NS" | sed 's/^/    /'
  printf '\n'
  ok "这就是 readiness 的正确行为：只摘流量，不动容器。"
  info "所以「依赖抖动」用 readiness 处理是安全的 —— 等恢复后流量会自动回来。"
  printf '\n'
  info "恢复探针路径……"
  kubectl patch deployment "$DEPLOY" -n "$NS" --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}
  ]' >/dev/null 2>&1
  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=180s >/dev/null 2>&1
  info "恢复后的 Endpoints："
  kubectl get endpoints "$DEPLOY" -n "$NS" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
if want 3; then
  bold "实验三：CrashLoopBackOff 的指数退避"
  rule
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  kubectl apply -f "$CASE_DIR/70-probes-demo.yaml" >/dev/null 2>&1
  info "观察 2 分半，注意 RESTARTS 的增长速度（应该越来越慢）："
  printf '\n  %-10s %-22s %s\n' "时间" "STATUS" "RESTARTS"
  printf '  %s\n' "--------------------------------------------------"
  for _ in $(seq 1 15); do
    line=$(kubectl get pod crash-demo -n "$NS" --no-headers 2>/dev/null | awk '{printf "%-22s %s", $3, $4}')
    printf '  %-10s %s\n' "$(date +%H:%M:%S)" "${line:-（还没创建）}"
    sleep 10
  done
  printf '\n'
  ok "退避节奏：10s → 20s → 40s → 80s … 上限 5 分钟"
  info "CrashLoopBackOff 不是「崩了」，而是「正在退避等待下一次重启」。"
  printf '\n'
  info "排查 CrashLoopBackOff 的第一把钥匙 —— 看上一次崩溃的日志："
  kubectl logs crash-demo -n "$NS" --previous 2>/dev/null | sed 's/^/    /' || info "    （暂时还没有上一次）"
  printf '\n'
  info "退出码与原因："
  kubectl get pod crash-demo -n "$NS" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}{"\n"}' 2>/dev/null | sed 's/^/    /'
  printf '\n'
  warn "注意：kubectl logs 不加 --previous 拿到的是「当前容器」的日志，可能是空的。"
  info "崩溃现场永远在 --previous 里。"
fi

# ---------------------------------------------------------------------------
if want 4; then
  bold "实验四：慢启动 + liveness 太急的死循环，以及 startupProbe 如何修复"
  rule
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  kubectl delete pod slow-start-broken slow-start-fixed -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  sleep 3
  kubectl apply -f "$CASE_DIR/70-probes-demo.yaml" >/dev/null 2>&1

  info "对比观察两个 Pod（各观察 100 秒）："
  printf '\n  %-10s %-34s %s\n' "时间" "slow-start-broken" "slow-start-fixed"
  printf '  %s\n' "--------------------------------------------------------------------------"
  for _ in $(seq 1 10); do
    b=$(kubectl get pod slow-start-broken -n "$NS" --no-headers 2>/dev/null | awk '{printf "%-20s R=%s", $3, $4}')
    f=$(kubectl get pod slow-start-fixed -n "$NS" --no-headers 2>/dev/null | awk '{printf "%-20s R=%s", $3, $4}')
    printf '  %-10s %-34s %s\n' "$(date +%H:%M:%S)" "${b:-...}" "${f:-...}"
    sleep 10
  done
  printf '\n'
  printf '    %-24s %-18s %s\n' "Pod" "STATUS" "RESTARTS"
  printf '    %s\n' "------------------------------------------------------------------"
  for p in slow-start-broken slow-start-fixed; do
    s=$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    r=$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
    printf '    %-24s %-18s %s\n' "$p" "${s:-?}" "${r:-?}"
  done
  printf '\n'
  ok "broken：启动要 40 秒，但 liveness 在第 15 秒就判死 → 永远起不来"
  ok "fixed ：多了 startupProbe（10 × 30 = 300 秒窗口）→ 40 秒后正常 Running"
  printf '\n'
  info "broken 的事件（证明是 liveness 在杀它）："
  kubectl describe pod slow-start-broken -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | grep -iE "liveness|unhealthy|killing" | head -4 | sed 's/^/    /'
  printf '\n'
  info "fixed 的日志（证明它真的启动了，且没被杀过）："
  kubectl logs slow-start-fixed -n "$NS" 2>/dev/null | tail -3 | sed 's/^/    /'
  printf '\n'
  warn "这就是 startupProbe 的价值：让「启动宽容」与「运行敏感」同时成立。"
fi

# ---------------------------------------------------------------------------
if want 5; then
  bold "实验五：三种探针职责分离的正确姿势"
  rule
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  kubectl apply -f "$CASE_DIR/70-probes-demo.yaml" >/dev/null 2>&1
  sleep 12
  printf '\n'
  kubectl get pod probe-compare -n "$NS" -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase' | sed 's/^/    /'
  printf '\n'
  info "它的探针配置（三种职责分离）："
  printf '      %-16s %s\n' "startupProbe" "给初始化留时间（最大 30 x 2 = 60 秒），成功后永久退出"
  printf '      %-16s %s\n' "readinessProbe" "决定能不能收流量 —— 失败只摘流量，不重启容器"
  printf '      %-16s %s\n' "livenessProbe" "决定要不要重启 —— 失败会杀死容器"
  printf '\n'
  ok "三条设计纪律："
  info "  ① /healthz（liveness）只检查进程自身，绝不查外部依赖"
  info "  ② /readyz（readiness）可以查依赖 —— 依赖抖动时摘流量即可"
  info "  ③ 两个端点必须是不同的实现，语义不同"
  printf '\n'
  warn "一句话判据：如果这个检查失败，重启容器能解决问题吗？"
  info "  能  → 适合做 liveness"
  info "  不能 → 只该做 readiness"
fi

# ---------------------------------------------------------------------------
if want 6; then
  bold "实验六：清理"
  rule
  cleanup
fi

printf '\n\033[1;32m实验完成。\033[0m对照第 11 章正文【积木 11-8】阅读效果最佳。\n\n'
