#!/usr/bin/env bash
# ============================================================================
# 第 15 章配套工具：集群与命名空间一体检
#
# 按「节点 → 控制面 → 调度 → 运行时/网络 → 应用」五层顺序输出一份体检报告。
# 只读操作，不修改任何东西。
#
# 用法：
#   bash cases/cloudnote/tools/diagnose.sh                 # 默认体检 cloudnote 命名空间
#   bash cases/cloudnote/tools/diagnose.sh <namespace>
#   bash cases/cloudnote/tools/diagnose.sh --cluster       # 只看集群层，不看命名空间
# ============================================================================
set -uo pipefail

NS="cloudnote"
CLUSTER_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --cluster) CLUSTER_ONLY=1 ;;
    -*) printf '未知参数：%s\n' "$arg"; exit 1 ;;
    *) NS="$arg" ;;
  esac
done

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  %s\033[0m\n' "$1"; }
bad()  { printf '\033[1;31m  %s\033[0m\n' "$1"; }
layer() { printf '\n\033[1;36m▎%s\033[0m\n' "$1"; }

command -v kubectl >/dev/null 2>&1 || { printf '找不到 kubectl。\n'; exit 1; }
if ! kubectl cluster-info >/dev/null 2>&1; then
  bad "连不上集群。请检查 kubeconfig 与网络。"
  exit 1
fi

printf '\n\033[1m╔══════════════════════════════════════════════════════════╗\033[0m\n'
printf '\033[1m║  K8s 体检报告\033[0m\n'
printf '\033[1m╚══════════════════════════════════════════════════════════╝\033[0m\n'
printf '  时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '  命名空间：%s\n' "$NS"

# ===========================================================================
layer "第 1 层：节点 —— 这台机器还活着吗？"
rule
kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /'

notready=$(kubectl get nodes --no-headers 2>/dev/null | grep -vc " Ready" || true)
if [ "$notready" -gt 0 ]; then
  bad "有 $notready 个节点不是 Ready —— 这是很多问题的源头"
  info "排查：kubectl describe node <node> | sed -n '/Conditions/,\$p'"
  info "      看 Conditions 里 MemoryPressure / DiskPressure / Ready 的状态"
else
  ok "所有节点 Ready"
fi

printf '\n'
info "节点可分配资源："
kubectl get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,PODS:.status.allocatable.pods' 2>/dev/null | sed 's/^/    /'

printf '\n'
info "节点污点（影响调度）："
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  t=$(kubectl get node "$n" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null)
  printf '    %-36s %s\n' "$n" "${t:-<无>}"
done

# ===========================================================================
layer "第 2 层：控制面 —— 集群还能思考吗？"
rule
if kubectl get --raw /readyz >/dev/null 2>&1; then
  ok "/readyz 通过"
  kubectl get --raw '/readyz?verbose' 2>/dev/null | grep -E "^\[" | sed 's/^/    /' | head -15
else
  bad "/readyz 不通过 —— 控制面有问题，所有操作都会受影响"
fi

printf '\n'
info "控制面组件（在 kind/kubeadm 里是静态 Pod）："
kubectl get pods -n kube-system 2>/dev/null | grep -E "NAME|apiserver|etcd|scheduler|controller-manager|metrics-server|coredns" | sed 's/^/    /' || info "    （读不到 kube-system）"

printf '\n'
info "选主状态（应该各有一个 holder）："
kubectl get lease -n kube-system 2>/dev/null | grep -E "NAME|controller-manager|scheduler" | sed 's/^/    /' || info "    （读不到 Lease）"

# ===========================================================================
if [ "$CLUSTER_ONLY" = "0" ]; then
  if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    bold "命名空间 $NS 不存在"
    info "如果这是实验环境，先跑：kubectl apply -f cases/cloudnote/00-namespace.yaml"
    printf '\n'
    exit 0
  fi

  layer "第 3 层：调度 —— Pod 被安排到机器上了吗？"
  rule
  kubectl get pods -n "$NS" -o wide 2>/dev/null | sed 's/^/  /'
  printf '\n'
  pending=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep -c Pending || true)
  if [ "$pending" -gt 0 ]; then
    warn "有 $pending 个 Pod 卡在 Pending"
    for p in $(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep Pending | awk '{print $1}'); do
      printf '\n    --- %s 的调度失败原因 ---\n' "$p"
      kubectl describe pod "$p" -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | grep -iE "failed|insufficient|taint|selector|volume" | head -3 | sed 's/^/      /'
    done
  else
    ok "没有 Pending 的 Pod"
  fi

  layer "第 4 层：运行时与网络 —— 容器起来了吗？能互通吗？"
  rule

  info "容器异常状态汇总："
  kubectl get pods -n "$NS" -o custom-columns='POD:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,WAITING:.status.containerStatuses[0].state.waiting.reason' 2>/dev/null | sed 's/^/    /'

  printf '\n'
  restarts=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$4+0 > 0 {print $1}' | wc -l | tr -d ' ')
  if [ "$restarts" -gt 0 ]; then
    warn "有 $restarts 个 Pod 发生过重启 —— 用 logs --previous 看崩溃现场"
    for p in $(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$4+0 > 0 {print $1}' | head -3); do
      printf '\n    --- %s 上一次退出的原因 ---\n' "$p"
      kubectl get pod "$p" -n "$NS" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' 2>/dev/null | sed 's/^/      /'
      printf '\n'
      kubectl logs "$p" -n "$NS" --previous --tail=5 2>/dev/null | sed 's/^/      /' || info "      （拿不到上一次的日志）"
    done
  else
    ok "没有异常重启"
  fi

  printf '\n'
  info "Service 与后端（Endpoints 为空 = 找不到后端）："
  svc_none=0
  for s in $(kubectl get svc -n "$NS" --no-headers 2>/dev/null | grep -v kubernetes | awk '{print $1}'); do
    ep=$(kubectl get endpoints "$s" -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    if [ -z "$ep" ]; then
      printf '    \033[1;31m%-28s <none>\033[0m\n' "$s"
      svc_none=$((svc_none+1))
    else
      printf '    %-28s %s\n' "$s" "$ep"
    fi
  done
  [ "$svc_none" -gt 0 ] && {
    printf '\n'
    bad "有 $svc_none 个 Service 没有后端"
    info "最常见的根因：Service 的 selector 与 Pod 标签不一致。核对一下："
    info "  kubectl get svc <name> -n $NS -o jsonpath='{.spec.selector}'"
    info "  kubectl get pods -n $NS --show-labels | head -5"
  }

  printf '\n'
  info "Ingress："
  kubectl get ingress,ingressclass -n "$NS" 2>/dev/null | sed 's/^/    /' || info "    （没有 Ingress 或读不到）"

  printf '\n'
  info "PVC 绑定情况："
  kubectl get pvc -n "$NS" 2>/dev/null | sed 's/^/    /' || info "    （没有 PVC）"
  pvcpend=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | grep -c -v Bound || true)
  if [ "$pvcpend" -gt 0 ]; then
    warn "有 $pvcpend 个 PVC 未 Bound"
    info "先确认：StorageClass 的 volumeBindingMode 是不是 WaitForFirstConsumer？"
    info "  kubectl get sc -o custom-columns='NAME:.metadata.name,BINDING:.volumeBindingMode'"
    info "该模式下 PVC 会等第一个用到它的 Pod 被调度后才创建卷 —— 这是设计，不是故障"
  fi

  layer "第 5 层：应用 —— 业务逻辑做对了吗？"
  rule
  warn "这一层 K8s 帮不了你。它只能证明「Pod 活着」，不能证明「业务正确」。"
  printf '\n'
  info "需要你自己检查的东西："
  printf '    %-30s %s\n' "业务日志有没有错误" "kubectl logs -l app=api -n $NS --tail=100 | grep -i error"
  printf '    %-30s %s\n' "QPS / 错误率 / P99" "看你的监控面板（K8s 不提供）"
  printf '    %-30s %s\n' "关键依赖是否可用" "数据库 / 缓存 / 下游 API 各自的状态"
  printf '    %-30s %s\n' "数据是否完整" "定期的一致性校验 / 备份验证"
  printf '\n'
  info "参考：第 14 章演习六演示了「Pod 全绿但业务全错」的场景。"

  # =========================================================================
  layer "附加：资源与弹性"
  rule
  info "HPA 状态（TARGETS 显示 unknown = 指标链路有问题）："
  kubectl get hpa -n "$NS" 2>/dev/null | sed 's/^/    /' || info "    （没有 HPA）"
  printf '\n'
  info "VPA 建议（如果有）："
  kubectl get vpa -n "$NS" 2>/dev/null | sed 's/^/    /' || info "    （没有 VPA 或 CRD 未安装）"
  printf '\n'
  info "实际用量（需要 metrics-server）："
  kubectl top pod -n "$NS" 2>/dev/null | sed 's/^/    /' || warn "    metrics-server 不可用，跳过"

  # =========================================================================
  layer "附加：最近的事件"
  rule
  warns=$(kubectl get events -n "$NS" --field-selector type=Warning --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$warns" -gt 0 ]; then
    warn "$warns 条 Warning 事件（默认只保留 1 小时，要趁早看）"
    kubectl get events -n "$NS" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -12 | sed 's/^/    /'
  else
    ok "没有 Warning 事件"
  fi
fi

# ===========================================================================
printf '\n'
printf '\033[1m╔══════════════════════════════════════════════════════════╗\033[0m\n'
printf '\033[1m║  体检结束\033[0m\n'
printf '\033[1m╚══════════════════════════════════════════════════════════╝\033[0m\n'
printf '\n'
printf '  排错顺序提醒（第 15 章五层模型）：\n'
printf '    节点 → 控制面 → 调度 → 运行时/网络 → 应用\n'
printf '    ↑ 从上往下，先确认上一层是好的，再往下查\n'
printf '\n'
printf '  黄金三条命令：\n'
printf '    kubectl get pods -n %s -o wide\n' "$NS"
printf '    kubectl describe pod <pod> -n %s | sed -n "/Events/\$,/p"\n' "$NS"
printf '    kubectl logs <pod> -n %s --previous\n' "$NS"
printf '\n'
