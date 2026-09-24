#!/usr/bin/env bash
# ============================================================================
# 第 12 章动手实验：看着 Pod 自己变多
#
# 六步：
#   1. 检查 / 安装 metrics-server（HPA 的前置条件）
#   2. 创建 HPA 与 VPA，看 TARGETS 那一列
#   3. 打流量 → 观察扩容（并验证 HPA 的比例公式）
#   4. 停流量 → 观察「缩容延迟」（stabilizationWindow 的作用）
#   5. 观察「扩了但 Pending」（本地集群没有 Cluster Autoscaler）
#   6. 用 VPA Off 模式拿资源建议
#
# 注意：本实验不安装集群级组件（metrics-server / VPA 组件）——脚本只做「检测 + 引导」，
#       避免擅自改动整个集群。metrics-server 是联网下载的，请确认网络可达。
#
# 用法：
#   bash cases/cloudnote/tools/autoscaling-lab.sh            # 跑全部
#   bash cases/cloudnote/tools/autoscaling-lab.sh 2 3 4      # 只跑指定步骤
#   bash cases/cloudnote/tools/autoscaling-lab.sh --cleanup  # 只做清理
# ============================================================================
set -uo pipefail

NS="cloudnote"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
LOAD_POD="load-generator"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
cmd()  { printf '\033[2m  $ %s\033[0m\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  %s\033[0m\n' "$1"; }

cleanup() {
  bold "清理实验资源"
  kubectl delete pod "$LOAD_POD" -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  kubectl delete hpa api worker -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete vpa api-vpa -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/35-worker.yaml" --ignore-not-found=true >/dev/null 2>&1
  ok "已清理 HPA / VPA / worker 与负载生成器。"
  info "metrics-server 是集群级组件，属于整个集群，不会删除。"
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

printf '\n\033[1;33m本实验会在 %s 命名空间创建 HPA / VPA / worker 与一个负载生成器 Pod。\033[0m\n' "$NS"
printf '\033[1;33m脚本不会擅自安装 metrics-server 等集群级组件，只会检测并给出安装指引。\033[0m\n'
printf '继续？(y/N) '
read -r answer
case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac

want() { for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

ensure_apps() {
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  kubectl get deployment api -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/20-api-deployment.yaml" >/dev/null
  kubectl get deployment worker -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/35-worker.yaml" >/dev/null
  kubectl rollout status deployment/api -n "$NS" --timeout=180s >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
if want 1; then
  bold "第 1 步：检查 metrics-server（HPA 的前置条件）"
  rule
  if kubectl top nodes >/dev/null 2>&1; then
    ok "metrics-server 工作正常，指标链路已通。"
    kubectl top nodes | sed 's/^/    /'
  else
    warn "kubectl top 不可用 —— 说明 metrics-server 没装或没就绪。"
    printf '\n'
    info "安装方法（kind / minikube）："
    printf '\n'
    info "  # ① 应用官方清单（需要网络可达）"
    info "  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
    printf '\n'
    info "  # ② kind 环境需要跳过一次 TLS 校验（kubelet 用自签证书）"
    info "  kubectl patch deployment metrics-server -n kube-system --type=json -p='["
    info "    {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--kubelet-insecure-tls\"}"
    info "  ]'"
    printf '\n'
    info "  # ③ 等它就绪"
    info "  kubectl rollout status deployment/metrics-server -n kube-system"
    info "  kubectl top nodes"
    printf '\n'
    warn "没有 metrics-server，HPA 的 TARGETS 会一直显示 <unknown>，完全不动。"
    info "装好之后重新跑本步骤。"
  fi
fi

# ---------------------------------------------------------------------------
if want 2; then
  bold "第 2 步：创建 HPA 与 VPA"
  rule
  ensure_apps
  cmd "kubectl apply -f cases/cloudnote/60-hpa.yaml"
  kubectl apply -f "$CASE_DIR/60-hpa.yaml" 2>&1 | sed 's/^/    /'
  sleep 5
  printf '\n'
  info "HPA 列表（重点看 TARGETS 那一列）："
  kubectl get hpa -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "VPA 列表："
  kubectl get vpa -n "$NS" 2>/dev/null | sed 's/^/    /' || warn "VPA 的 CRD 没装（需要装 VPA 组件），跳过"
  printf '\n'
  ok "TARGETS 的含义："
  info "  有数值（如 1%/50%）→ 指标链路正常"
  info "  <unknown>/50%      → metrics-server 有问题，或容器没写 requests"
  printf '\n'
  info "worker 那个 HPA 的 TARGETS 大概会是 <unknown> —— 这是【预期行为】："
  info "  它用的是 External 指标（队列积压量），需要集群里装 prometheus-adapter 之类的 adapter。"
  info "  这正好说明「指标源缺了会怎样」。"
fi

# ---------------------------------------------------------------------------
if want 3; then
  bold "第 3 步：打流量 → 观察扩容"
  rule
  ensure_apps
  kubectl get hpa api -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/60-hpa.yaml" >/dev/null 2>&1

  info "当前状态："
  kubectl get hpa api -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "启动负载生成器（在 api 容器里跑 CPU 密集操作）……"
  kubectl delete pod "$LOAD_POD" -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  kubectl run "$LOAD_POD" -n "$NS" --image=busybox:1.36 --restart=Never \
    --command -- sh -c "while true; do wget -q -O- http://api:8080/ >/dev/null 2>&1 || sleep 1; done" >/dev/null 2>&1
  # 同时在 api 容器里制造 CPU 压力
  for p in $(kubectl get pods -n "$NS" -l app=api -o jsonpath='{.items[*].metadata.name}'); do
    kubectl exec "$p" -n "$NS" -- sh -c 'nohup sh -c "while true; do :; done" >/dev/null 2>&1 &' >/dev/null 2>&1 || true
  done

  printf '\n'
  info "观察 3 分钟（每 15 秒采样一次）："
  printf '\n  %-10s %s\n' "时间" "HPA 状态（NAME TARGETS REPLICAS）"
  printf '  %s\n' "------------------------------------------------------------"
  for _ in $(seq 1 12); do
    st=$(kubectl get hpa api -n "$NS" --no-headers 2>/dev/null | awk '{printf "TARGETS=%-12s REPLICAS=%s", $3, $6}')
    printf '  %-10s %s\n' "$(date +%H:%M:%S)" "${st:-（还没就绪）}"
    sleep 15
  done
  printf '\n'
  ok "验证 HPA 的比例公式：期望副本数 = ceil(当前副本 × 当前指标 / 目标指标)"
  info "例：TARGETS=118%、当前 2 副本 → ceil(2 × 118/50) = ceil(4.72) = 5"
  printf '\n'
  info "HPA 的实际决策记录："
  kubectl describe hpa api -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | tail -6 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
if want 4; then
  bold "第 4 步：停流量 → 观察「缩容延迟」"
  rule
  info "停掉负载生成器与容器内的 CPU 压力……"
  kubectl delete pod "$LOAD_POD" -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  for p in $(kubectl get pods -n "$NS" -l app=api -o jsonpath='{.items[*].metadata.name}'); do
    kubectl exec "$p" -n "$NS" -- sh -c 'pkill -f "while true" 2>/dev/null || true' >/dev/null 2>&1 || true
  done
  sleep 20
  printf '\n'
  info "现在开始每 30 秒采样一次，观察 REPLICAS 的变化："
  printf '\n  %-10s %s\n' "时间" "HPA 状态"
  printf '  %s\n' "------------------------------------------------------------"
  for _ in $(seq 1 12); do
    st=$(kubectl get hpa api -n "$NS" --no-headers 2>/dev/null | awk '{printf "TARGETS=%-12s REPLICAS=%s", $3, $6}')
    printf '  %-10s %s\n' "$(date +%H:%M:%S)" "${st:-...}"
    sleep 30
  done
  printf '\n'
  ok "关键观察：TARGETS 立刻降了，但 REPLICAS 要等约 5 分钟才开始缩。"
  info "这就是 behavior.scaleDown.stabilizationWindowSeconds: 300 的作用 ——"
  info "缩容前先观察 5 分钟，万一流量马上回来就不缩了。"
  printf '\n'
  warn "如果你以为「HPA 坏了」或「缩容不工作」，先看这个观察窗口。"
fi

# ---------------------------------------------------------------------------
if want 5; then
  bold "第 5 步：观察「扩了但 Pending」（本地集群没有 Cluster Autoscaler）"
  rule
  ensure_apps
  kubectl get hpa api -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/60-hpa.yaml" >/dev/null 2>&1

  info "把 maxReplicas 调到 50，然后打流量，看集群装不装得下……"
  kubectl patch hpa api -n "$NS" -p '{"spec":{"maxReplicas":50}}' >/dev/null 2>&1
  kubectl delete pod "$LOAD_POD" -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  kubectl run "$LOAD_POD" -n "$NS" --image=busybox:1.36 --restart=Never \
    --command -- sh -c "while true; do wget -q -O- http://api:8080/ >/dev/null 2>&1 || sleep 1; done" >/dev/null 2>&1
  for p in $(kubectl get pods -n "$NS" -l app=api -o jsonpath='{.items[*].metadata.name}'); do
    kubectl exec "$p" -n "$NS" -- sh -c 'nohup sh -c "while true; do :; done" >/dev/null 2>&1 &' >/dev/null 2>&1 || true
  done

  info "等 90 秒让 HPA 决策……"
  sleep 90
  printf '\n'
  info "HPA 想要的副本数："
  kubectl get hpa api -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "Pod 实际状态（注意有没有 Pending）："
  kubectl get pods -n "$NS" -l app=api -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName' | sed 's/^/    /'
  printf '\n'
  pd=$(kubectl get pods -n "$NS" -l app=api --no-headers 2>/dev/null | grep -c Pending || true)
  if [ "$pd" -gt 0 ]; then
    warn "有 $pd 个 Pod 卡在 Pending —— 这就是「两个层次的伸缩没接上」。"
    info "Events："
    P=$(kubectl get pods -n "$NS" -l app=api --no-headers 2>/dev/null | grep Pending | head -1 | awk '{print $1}')
    kubectl describe pod "$P" -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | head -6 | sed 's/^/    /'
    printf '\n'
    info "HPA 只管「要几个 Pod」，【完全不管节点装不装得下】。"
    info "在云上，这时候 Cluster Autoscaler 会开始加机器（1~3 分钟）。"
    info "在本地集群没有 CA，所以 Pod 会一直 Pending。"
  else
    ok "没有 Pending —— 说明你的集群节点资源还够。"
    info "想复现这个现象，可以把 maxReplicas 调更高，或者把 requests 调大。"
  fi
  printf '\n'
  info "恢复 maxReplicas 为 10 ……"
  kubectl patch hpa api -n "$NS" -p '{"spec":{"maxReplicas":10}}' >/dev/null 2>&1
  kubectl delete pod "$LOAD_POD" -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
if want 6; then
  bold "第 6 步：用 VPA 的 Off 模式拿资源建议"
  rule
  ensure_apps
  if ! kubectl get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1; then
    warn "集群里没装 VPA 的 CRD，跳过本步骤。"
    printf '\n'
    info "安装 VPA（官方仓库，需要网络可达）："
    info "  git clone https://github.com/kubernetes/autoscaler.git"
    info "  cd autoscaler/vertical-pod-autoscaler && ./hack/vpa-up.sh"
    info "（或者用你集群平台提供的 VPA 安装方式）"
    printf '\n'
    info "注意：VPA 需要一个准入控制器（admission controller），"
    info "      否则 updateMode 不是 Off 的那几种模式不会生效。"
  else
    kubectl apply -f "$CASE_DIR/60-hpa.yaml" >/dev/null 2>&1
    info "VPA（updateMode: Off）已就位，等它收集数据……"
    printf '\n'
    info "  注意：Off 模式只计算建议、不改任何东西，所以没有任何风险。"
    info "        这也是 VPA 在生产上最主流的用法 —— 当「资源顾问」。"
    printf '\n'
    for i in $(seq 1 6); do
      printf '    第 %s 次采样（%s）...\n' "$i" "$(date +%H:%M:%S)"
      sleep 30
    done
    printf '\n'
    info "VPA 给出的建议："
    kubectl describe vpa api-vpa -n "$NS" 2>/dev/null | sed -n '/Recommendation/,$p' | head -12 | sed 's/^/    /'
    printf '\n'
    info "当前 Deployment 里的 requests："
    kubectl get deploy api -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.requests}{"\n"}' 2>/dev/null | sed 's/^/    /'
    printf '\n'
    ok "把 VPA 建议的 Target 值写回 Deployment 的 requests —— 这就是「校准过的 requests」。"
    warn "为什么这一步重要：HPA 的 CPU 利用率 = 实际用量 ÷ requests。"
    info "requests 校准了，HPA 才能算对；requests 不准，自动伸缩只会把错误放大。"
  fi
fi

printf '\n\033[1;33m是否清理本次实验创建的资源？(y/N) \033[0m'
read -r answer
case "$answer" in y|Y) cleanup ;; *) info "保留现场。随时可用 --cleanup 清理。" ;; esac

printf '\n\033[1;32m实验完成。\033[0m对照第 12 章正文【积木 12-10】阅读效果最佳。\n\n'
