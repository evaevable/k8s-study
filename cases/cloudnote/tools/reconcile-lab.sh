#!/usr/bin/env bash
# ============================================================================
# 第 4 章动手实验：亲眼看见调和循环（Reconciliation Loop）
#
# 这个脚本会创建/删除自己专用的资源，名字都带 api-lab 前缀。
# 它**不会**动 cloudnote 命名空间里的其他任何东西。
# 但为了安全，运行前仍会要求你确认。
#
# 用法：
#   bash cases/cloudnote/tools/reconcile-lab.sh              # 跑全部实验
#   bash cases/cloudnote/tools/reconcile-lab.sh 1 3          # 只跑实验 1 和 3
#   bash cases/cloudnote/tools/reconcile-lab.sh --cleanup    # 只做清理
# ============================================================================
set -uo pipefail

NS="cloudnote"
DEPLOY="api-lab"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TOOLS_DIR/../../.." && pwd)"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }

if ! command -v kubectl >/dev/null 2>&1; then
  printf '找不到 kubectl，请先安装并配置 kubeconfig。\n'
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  printf '连不上集群。请先按第 1 章【积木 1-10】起一个集群。\n'
  exit 1
fi

cleanup() {
  bold "清理实验资源"
  kubectl delete deployment "$DEPLOY" -n "$NS" --ignore-not-found=true
  kubectl delete pods -n "$NS" -l "orphan-demo=true" --ignore-not-found=true 2>/dev/null
  ok "清理完成。命名空间 $NS 里其他资源未受影响。"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
CLEANUP_ONLY=0
EXPERIMENTS=()
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP_ONLY=1 ;;
    1|2|3|4|5) EXPERIMENTS+=("$arg") ;;
    *) printf '未知参数：%s\n' "$arg"; exit 1 ;;
  esac
done

if [ "$CLEANUP_ONLY" = "1" ]; then
  cleanup
  exit 0
fi

if [ "${#EXPERIMENTS[@]}" -eq 0 ]; then
  EXPERIMENTS=(1 2 3 4 5)
fi

printf '\n\033[1;33m即将在命名空间 %s 中创建名为 %s 的 Deployment（3 个 nginx 副本）\033[0m\n' "$NS" "$DEPLOY"
printf '它只用于第 4 章实验，实验结束会自动删除。\n'
printf '继续？(y/N) '
read -r answer
case "$answer" in
  y|Y) ;;
  *) printf '已取消。\n'; exit 0 ;;
esac

want() {
  for e in "${EXPERIMENTS[@]}"; do [ "$e" = "$1" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# 实验 1：删掉一个 Pod，看控制器补回来
# ---------------------------------------------------------------------------
run_exp1() {
  bold "实验 1：删掉一个 Pod，看它被补回来"
  rule
  info "准备：创建 3 副本 Deployment"
  kubectl create deployment "$DEPLOY" -n "$NS" \
    --image=nginx:1.27-alpine --replicas=3 >/dev/null 2>&1

  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=120s >/dev/null 2>&1

  info "当前 Pod（注意记下这些名字）："
  kubectl get pods -n "$NS" -l "app=$DEPLOY" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,START:.status.startTime'
  BEFORE=$(kubectl get pods -n "$NS" -l "app=$DEPLOY" -o jsonpath='{.items[*].metadata.name}')
  info "删除前的 Pod：$BEFORE"

  VICTIM=$(kubectl get pods -n "$NS" -l "app=$DEPLOY" -o jsonpath='{.items[0].metadata.name}')
  printf '\n'
  info "现在删除：$VICTIM（记录时间：$(date +%H:%M:%S)）"
  kubectl delete pod "$VICTIM" -n "$NS" --wait=false >/dev/null 2>&1

  info "删除后立刻查看："
  kubectl get pods -n "$NS" -l "app=$DEPLOY" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,START:.status.startTime'

  # 等新 Pod 就绪
  for _ in $(seq 1 30); do
    ready=$(kubectl get pods -n "$NS" -l "app=$DEPLOY" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
      | grep -c '^True$' || true)
    [ "$ready" = "3" ] && break
    sleep 2
  done

  printf '\n'
  info "收敛后的 Pod："
  kubectl get pods -n "$NS" -l "app=$DEPLOY" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,START:.status.startTime'
  printf '\n'
  info "观察要点："
  info "  - $VICTIM 这个名字不会再出现（Pod 是一次性的）"
  info "  - 出现了一个全新名字的 Pod，启动时间就是刚才那一秒"
  info "  - 控制器不知道「谁被删了」，它只是重新数了一遍：期望 3，实际 2，补 1 个"
}

# ---------------------------------------------------------------------------
# 实验 2：改标签制造孤儿，证明控制器「只数数，不认人」
# ---------------------------------------------------------------------------
run_exp2() {
  bold "实验 2：把标签改掉，制造一个「孤儿 Pod」"
  rule
  if ! kubectl get deployment "$DEPLOY" -n "$NS" >/dev/null 2>&1; then
    info "先创建 Deployment"
    kubectl create deployment "$DEPLOY" -n "$NS" \
      --image=nginx:1.27-alpine --replicas=3 >/dev/null 2>&1
    kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=120s >/dev/null 2>&1
  fi

  ORPHAN=$(kubectl get pods -n "$NS" -l "app=$DEPLOY" -o jsonpath='{.items[0].metadata.name}')
  info "即将把 $ORPHAN 的标签从 app=$DEPLOY 改成 app=somebody-else"
  kubectl label pod "$ORPHAN" -n "$NS" app=somebody-else orphan-demo=true --overwrite >/dev/null 2>&1

  sleep 4

  printf '\n'
  info "① 符合 app=$DEPLOY 的 Pod（ReplicaSet 统计的范围）："
  kubectl get pods -n "$NS" -l "app=$DEPLOY" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'
  printf '\n'
  info "② 被你改掉标签的那个 Pod（它现在还活着）："
  kubectl get pod "$ORPHAN" -n "$NS" --show-labels 2>/dev/null || info "（已被清理）"
  printf '\n'
  info "③ 整个 Deployment 名下的 Pod 总数："
  info "  ReplicaSet 数出来的是 3 个（它补了一个新的）"
  info "  但你实际拥有 4 个 Pod —— 多出来的那个成了孤儿"
  printf '\n'
  info "结论：控制器的判断依据是「符合标签的 Pod 有几个」，不是「哪个 Pod 存在」。"
  info "      标签是 K8s 里对象之间关系的唯一凭据 —— 改了标签，关系就断了。"
  printf '\n'
  info "清理这个孤儿："
  kubectl delete pod "$ORPHAN" -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  ok "孤儿已删除（注意：删掉它不会触发控制器补 Pod，因为它在选择器之外）"
}

# ---------------------------------------------------------------------------
# 实验 3：观察收敛与幂等
# ---------------------------------------------------------------------------
run_exp3() {
  bold "实验 3：扩容 / 缩容，观察「收敛」与「幂等」"
  rule
  if ! kubectl get deployment "$DEPLOY" -n "$NS" >/dev/null 2>&1; then
    kubectl create deployment "$DEPLOY" -n "$NS" \
      --image=nginx:1.27-alpine --replicas=1 >/dev/null 2>&1
  fi

  info "① 扩到 5"
  kubectl scale deployment "$DEPLOY" -n "$NS" --replicas=5 >/dev/null 2>&1
  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=120s >/dev/null 2>&1
  kubectl get pods -n "$NS" -l "app=$DEPLOY" --no-headers | wc -l | xargs printf '  实际 Pod 数：%s\n'

  info "② 缩到 2（注意：控制器是按「数量」删的，不指定删哪个）"
  kubectl scale deployment "$DEPLOY" -n "$NS" --replicas=2 >/dev/null 2>&1
  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=120s >/dev/null 2>&1
  kubectl get pods -n "$NS" -l "app=$DEPLOY" --no-headers | wc -l | xargs printf '  实际 Pod 数：%s\n'

  info "③ 反复 10 次把副本数设为 2（如果是非幂等的，这里会出乱子）"
  for _ in $(seq 1 10); do
    kubectl scale deployment "$DEPLOY" -n "$NS" --replicas=2 >/dev/null 2>&1
  done
  sleep 3
  kubectl get pods -n "$NS" -l "app=$DEPLOY" --no-headers | wc -l | xargs printf '  实际 Pod 数：%s\n'
  ok "依然是 2 —— 同一个调谐循环跑 1 次和跑 1000 次，结果一样。这就是幂等。"
}

# ---------------------------------------------------------------------------
# 实验 4：制造一次 409 Conflict
# ---------------------------------------------------------------------------
run_exp4() {
  bold "实验 4：制造一次 409 Conflict（乐观并发）"
  rule
  if ! kubectl get deployment "$DEPLOY" -n "$NS" >/dev/null 2>&1; then
    kubectl create deployment "$DEPLOY" -n "$NS" \
      --image=nginx:1.27-alpine --replicas=3 >/dev/null 2>&1
    kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=120s >/dev/null 2>&1
  fi

  TMP=$(mktemp -t k8s-lab.XXXXXX.json)
  info "① 导出当前对象到 $TMP（记录下此刻的 resourceVersion）"
  kubectl get deployment "$DEPLOY" -n "$NS" -o json > "$TMP"
  RV=$(kubectl get deployment "$DEPLOY" -n "$NS" -o jsonpath='{.metadata.resourceVersion}')
  info "   读到的 resourceVersion = $RV"

  info "② 在「读」和「写」之间，让另一个人改一下这个对象"
  kubectl annotate deployment "$DEPLOY" -n "$NS" \
    "lab-conflict=$(date +%s)" --overwrite >/dev/null 2>&1
  NEW_RV=$(kubectl get deployment "$DEPLOY" -n "$NS" -o jsonpath='{.metadata.resourceVersion}')
  info "   现在的 resourceVersion = $NEW_RV（已经变了）"

  info "③ 用那份「过期」的 JSON 写回，应该报 Conflict"
  printf '\n'
  kubectl replace -f "$TMP" 2>&1 | sed 's/^/  /'
  printf '\n'
  ok "那行 the object has been modified 就是乐观并发的实体。"
  info "正确做法：重新读一遍再改（控制器里的做法是整轮调谐重来）。"
  rm -f "$TMP"
}

# ---------------------------------------------------------------------------
# 实验 5：同时删多个 Pod，观察去重队列仍然收敛
# ---------------------------------------------------------------------------
run_exp5() {
  bold "实验 5：同时删掉多个 Pod，看它是否还能收敛"
  rule
  kubectl scale deployment "$DEPLOY" -n "$NS" --replicas=3 >/dev/null 2>&1
  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=120s >/dev/null 2>&1

  PODS=$(kubectl get pods -n "$NS" -l "app=$DEPLOY" -o jsonpath='{.items[*].metadata.name}')
  info "同时删除全部 3 个 Pod：$PODS"
  for p in $PODS; do
    kubectl delete pod "$p" -n "$NS" --wait=false >/dev/null 2>&1 &
  done
  wait

  info "等待收敛……"
  for _ in $(seq 1 60); do
    ready=$(kubectl get pods -n "$NS" -l "app=$DEPLOY" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
      | grep -c '^True$' || true)
    [ "$ready" = "3" ] && break
    sleep 2
  done

  printf '\n'
  kubectl get pods -n "$NS" -l "app=$DEPLOY" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,START:.status.startTime'
  printf '\n'
  info "三个删除事件几乎同时到达，可能被 WorkQueue 去重合并成 1 次调谐。"
  info "但结果依然精确收敛到 3 个 —— 因为控制器每次都会「重新数一遍」，"
  info "它不依赖任何一个事件被完整送达。这就是水平触发的威力。"
}

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------
for e in "${EXPERIMENTS[@]}"; do
  case "$e" in
    1) run_exp1 ;;
    2) run_exp2 ;;
    3) run_exp3 ;;
    4) run_exp4 ;;
    5) run_exp5 ;;
  esac
done

cleanup
printf '\n\033[1;32m全部实验完成。\033[0m对照第 4 章正文【积木 4-10】阅读效果最佳。\n\n'
