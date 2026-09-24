#!/usr/bin/env bash
# ============================================================================
# 第 10 章动手实验：把资源与调度的行为都看一遍
#
# 八步：
#   1. 看节点可分配资源与已分配情况（Requests 才是调度依据，Limits 可超卖）
#   2. requests 太高 → FailedScheduling（Insufficient cpu）
#   3. CPU 限流 → 静默的变慢（Running、RESTARTS 0、无 Event）
#   4. 内存超限 → OOMKilled（RESTARTS 增长、exitCode 137）
#   5. 三个 QoS 等级长什么样
#   6. topologySpreadConstraints：软性 vs 硬性打散的差别
#   7. taint 如何阻止调度，以及 toleration 如何放行
#   8. 清理
#
# 注意：本实验会创建一些「故意异常」的 Pod（OOM、Pending），只在实验集群用。
#       第 7 步会临时改节点污点，脚本结束时会自动移除。
#
# 用法：
#   bash cases/cloudnote/tools/scheduling-lab.sh            # 跑全部
#   bash cases/cloudnote/tools/scheduling-lab.sh 2 3 4      # 只跑指定步骤
#   bash cases/cloudnote/tools/scheduling-lab.sh --cleanup  # 只做清理
# ============================================================================
set -uo pipefail

NS="cloudnote"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
TAINT_KEY="purpose"
TAINT_VAL="reserved"
TAINTED_NODE=""

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
cmd()  { printf '\033[2m  $ %s\033[0m\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  %s\033[0m\n' "$1"; }

# 兜底：无论如何都要把污点摘掉，否则会影响后续实验
remove_taint() {
  if [ -n "$TAINTED_NODE" ]; then
    kubectl taint nodes "$TAINTED_NODE" "${TAINT_KEY}=${TAINT_VAL}:NoSchedule-" >/dev/null 2>&1
  fi
}
trap remove_taint EXIT

cleanup() {
  bold "清理实验资源"
  remove_taint
  kubectl delete -f "$CASE_DIR/28-scheduling-demo.yaml" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete pod cpu-throttle taint-test taint-tolerated -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  ok "已清理全部演示对象，并确保节点污点已被移除。"
}

CLEANUP_ONLY=0
STEPS=()
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP_ONLY=1 ;;
    1|2|3|4|5|6|7|8) STEPS+=("$arg") ;;
    *) printf '未知参数：%s\n' "$arg"; exit 1 ;;
  esac
done

if [ "$CLEANUP_ONLY" = "1" ]; then cleanup; exit 0; fi
[ "${#STEPS[@]}" -eq 0 ] && STEPS=(1 2 3 4 5 6 7 8)

command -v kubectl >/dev/null 2>&1 || { printf '找不到 kubectl。\n'; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { printf '连不上集群。请先按第 1 章【积木 1-10】起一个集群。\n'; exit 1; }

printf '\n\033[1;33m本实验会在 %s 命名空间创建若干「故意异常」的演示 Pod，并临时修改一个节点的污点。\033[0m\n' "$NS"
printf '\033[1;33m脚本结束时会自动清理。请只在实验集群运行。\033[0m\n'
printf '继续？(y/N) '
read -r answer
case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac

want() { for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# ---------------------------------------------------------------------------
if want 1; then
  bold "第 1 步：节点可分配资源 vs 已分配情况"
  rule
  info "① 节点的可分配资源："
  kubectl get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,PODS:.status.allocatable.pods' | sed 's/^/    /'
  printf '\n'
  NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  info "② $NODE 已分配出去多少（注意：这是 requests 之和，不是实际用量）："
  kubectl describe node "$NODE" 2>/dev/null | sed -n '/Allocated resources/,/Events/p' | sed 's/^/    /'
  printf '\n'
  ok "两个要点："
  info "  · Requests 那一列才是调度依据 —— 超过 100% 就再也放不下新 Pod"
  info "  · Limits 可以超卖（175% 很正常），因为不是所有 Pod 会同时打满"
fi

# ---------------------------------------------------------------------------
if want 2; then
  bold "第 2 步：requests 太高 → FailedScheduling"
  rule
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  kubectl delete pod too-big -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  sleep 2
  kubectl apply -f "$CASE_DIR/28-scheduling-demo.yaml" >/dev/null 2>&1
  sleep 8
  printf '\n'
  info "Pod 状态："
  kubectl get pod too-big -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "Events（这就是第 3 章 Filter 阶段的真实报错）："
  kubectl describe pod too-big -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | sed 's/^/    /'
  printf '\n'
  ok "关键：容器实际只用 1m CPU，但 requests 写了 100 核 —— 调度器只认 requests。"
  info "所以「我留了很大余量，为什么调度不上去」的答案往往就是 requests 写高了。"
fi

# ---------------------------------------------------------------------------
if want 3; then
  bold "第 3 步：CPU 限流 —— 静默的变慢"
  rule
  kubectl delete pod cpu-throttle -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  sleep 2
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cpu-throttle
  namespace: cloudnote
spec:
  containers:
    - name: busy
      image: busybox:1.36
      command: ["sh","-c","while true; do :; done"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 50m
          memory: 32Mi
EOF
  info "让它跑 20 秒，把 CPU 打满……"
  sleep 20
  printf '\n'
  info "① Pod 状态（注意 RESTARTS 是 0，看起来完全正常）："
  kubectl get pod cpu-throttle -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "② 有没有任何 Event？"
  ev=$(kubectl describe pod cpu-throttle -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | grep -v "^Events:" | grep -v "^  Type" | grep -v "^  ----" | grep -v "^\s*$" | head -3)
  if [ -z "$ev" ]; then
    printf '    （没有任何 Event）\n'
  else
    printf '    %s\n' "$ev"
  fi
  printf '\n'
  info "③ 被限流的数据（cgroup v2）："
  kubectl exec cpu-throttle -n "$NS" -- cat /sys/fs/cgroup/cpu.stat 2>/dev/null | head -5 | sed 's/^/    /' \
    || info "    （读不到 cgroup，可能是 v1 或权限限制）"
  printf '\n'
  ok "Pod 完全正常：Running、RESTARTS 0、没有 Event。但 CPU 被死死限制在 50m。"
  warn "这就是「CPU 限流是静默的」的实证 —— 生产上只能靠监控 throttled 指标发现。"
  kubectl delete pod cpu-throttle -n "$NS" --wait=false >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
if want 4; then
  bold "第 4 步：内存超限 → OOMKilled"
  rule
  kubectl delete pod oom-demo -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  sleep 2
  kubectl apply -f "$CASE_DIR/28-scheduling-demo.yaml" >/dev/null 2>&1
  info "让它试着吃 200Mi 内存（limit 只有 64Mi），等 30 秒……"
  sleep 30
  printf '\n'
  info "① Pod 状态（RESTARTS 应该在涨）："
  kubectl get pod oom-demo -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "② 上一次退出的原因："
  kubectl get pod oom-demo -n "$NS" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}' 2>/dev/null | sed 's/^/    /'
  printf '\n'
  info "③ 退出码（137 = 128 + 9，即被 SIGKILL 杀死）："
  kubectl get pod oom-demo -n "$NS" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}' 2>/dev/null | sed 's/^/    /'
  printf '\n'
  ok "对比第 3 步："
  printf '    %-16s %-28s %s\n' "超限的资源" "Pod 状态" "有 Event 吗"
  printf '    %s\n' "------------------------------------------------------------------"
  printf '    %-16s %-28s %s\n' "CPU" "Running，RESTARTS: 0" "没有"
  printf '    %-16s %-28s %s\n' "内存" "RESTARTS 持续增长" "有（OOMKilling）"
  printf '\n'
  info "这就是「可压缩 vs 不可压缩」最直观的证明。"
fi

# ---------------------------------------------------------------------------
if want 5; then
  bold "第 5 步：三个 QoS 等级长什么样"
  rule
  kubectl apply -f "$CASE_DIR/28-scheduling-demo.yaml" >/dev/null 2>&1
  sleep 10
  printf '\n'
  kubectl get pods -n "$NS" -l purpose=chapter-10-demo \
    -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass,STATUS:.status.phase' | sed 's/^/    /'
  printf '\n'
  for p in qos-guaranteed qos-burstable qos-besteffort; do
    printf '    --- %s ---\n' "$p"
    kubectl get pod "$p" -n "$NS" -o jsonpath='{.spec.containers[0].resources}{"\n"}' 2>/dev/null | sed 's/^/      /'
  done
  printf '\n'
  ok "QoS 不是你手写的，是 K8s 根据 requests/limits 的关系自动推导的："
  info "  requests == limits  → Guaranteed（最后被驱逐）"
  info "  requests <  limits  → Burstable"
  info "  完全没写            → BestEffort（第一个被驱逐）"
  printf '\n'
  warn "注意：QoS 不是「性能保证」，而是「被驱逐的优先级」。"
fi

# ---------------------------------------------------------------------------
if want 6; then
  bold "第 6 步：软性 vs 硬性打散"
  rule
  kubectl apply -f "$CASE_DIR/28-scheduling-demo.yaml" >/dev/null 2>&1
  sleep 15
  WORKERS=$(kubectl get nodes --no-headers 2>/dev/null | grep -vc control-plane || echo 0)
  printf '\n'
  info "当前可调度的 worker 节点数：$WORKERS"
  printf '\n'
  info "① 硬性打散（whenUnsatisfiable: DoNotSchedule）的三个副本："
  kubectl get pods -n "$NS" -l app=spread-hard \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName' 2>/dev/null | sed 's/^/    /'
  printf '\n'
  pending=$(kubectl get pods -n "$NS" -l app=spread-hard --no-headers 2>/dev/null | grep -c Pending || true)
  if [ "$pending" -gt 0 ]; then
    warn "有 $pending 个副本卡在 Pending —— 因为节点数少于副本数，硬性打散不允许不均衡。"
    info "Events："
    P=$(kubectl get pods -n "$NS" -l app=spread-hard --no-headers 2>/dev/null | grep Pending | head -1 | awk '{print $1}')
    kubectl describe pod "$P" -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | sed 's/^/    /' | head -8
    printf '\n'
    info "对比：如果改成 ScheduleAnyway（第 10 章【积木 10-6】的推荐做法），"
    info "它会退化成「尽量均衡」，两个副本可以落在同一节点，不会 Pending。"
  else
    ok "副本全部调度成功 —— 说明节点数 >= 3，硬性打散完美生效（每个节点最多 1 个）。"
  fi
fi

# ---------------------------------------------------------------------------
if want 7; then
  bold "第 7 步：taint 如何阻止调度，toleration 如何放行"
  rule
  TAINTED_NODE=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v control-plane | head -1)
  if [ -z "$TAINTED_NODE" ]; then
    warn "找不到 worker 节点，跳过。"
  else
    info "选中节点：$TAINTED_NODE"
    kubectl taint nodes "$TAINTED_NODE" "${TAINT_KEY}=${TAINT_VAL}:NoSchedule" 2>&1 | sed 's/^/    /'
    printf '\n'
    kubectl delete pod taint-test -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
    sleep 2
    kubectl run taint-test -n "$NS" --image=busybox:1.36 --restart=Never \
      --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sh","-c","sleep 3600"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"}}}]}}' >/dev/null 2>&1
    sleep 8
    printf '\n'
    info "① 普通 Pod 的结果："
    kubectl get pod taint-test -n "$NS" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName' 2>/dev/null | sed 's/^/    /'
    printf '\n'
    st=$(kubectl get pod taint-test -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$st" = "Pending" ]; then
      warn "卡在 Pending —— 集群只有这一个 worker，没有别的去处。"
      kubectl describe pod taint-test -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | grep -i taint | head -2 | sed 's/^/    /'
    else
      ok "它被调度到了没有污点的节点上（说明集群有多个 worker）。"
    fi
    printf '\n'
    info "② 加上 toleration 的 Pod："
    kubectl delete pod taint-tolerated -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
    sleep 2
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: taint-tolerated
  namespace: cloudnote
spec:
  tolerations:
    - key: ${TAINT_KEY}
      operator: Equal
      value: "${TAINT_VAL}"
      effect: NoSchedule
  containers:
    - name: demo
      image: busybox:1.36
      command: ["sh","-c","sleep 3600"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
EOF
    sleep 8
    kubectl get pod taint-tolerated -n "$NS" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName' 2>/dev/null | sed 's/^/    /'
    printf '\n'
    ok "它就能落到带污点的节点上了 —— 这就是「专用节点池」的实现方式。"
    info "移除污点（脚本退出时也会兜底移除）："
    kubectl taint nodes "$TAINTED_NODE" "${TAINT_KEY}=${TAINT_VAL}:NoSchedule-" 2>&1 | sed 's/^/    /'
    TAINTED_NODE=""
  fi
fi

# ---------------------------------------------------------------------------
if want 8; then
  bold "第 8 步：清理"
  rule
  cleanup
fi

printf '\n\033[1;32m实验完成。\033[0m对照第 10 章正文【积木 10-8】阅读效果最佳。\n\n'
