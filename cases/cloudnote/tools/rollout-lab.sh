#!/usr/bin/env bash
# ============================================================================
# 第 5 章动手实验：发布、观察滚动更新、故意搞坏、回滚
#
# 全程只操作 cloudnote 命名空间里名为 api 的 Deployment。
# 用改环境变量触发发布（不依赖第二个镜像），用不存在的镜像 tag 制造故障。
#
# 用法：
#   bash cases/cloudnote/tools/rollout-lab.sh            # 跑全部十个步骤
#   bash cases/cloudnote/tools/rollout-lab.sh 1 2 7      # 只跑指定步骤
#   bash cases/cloudnote/tools/rollout-lab.sh --cleanup  # 只做清理
# ============================================================================
set -uo pipefail

NS="cloudnote"
DEPLOY="api"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$TOOLS_DIR/.." && pwd)"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
cmd()  { printf '\033[2m  $ %s\033[0m\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  %s\033[0m\n' "$1"; }
stamp() { date +%H:%M:%S; }

wait_ready() {
  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=180s >/dev/null 2>&1
}

cleanup() {
  bold "清理实验资源"
  kubectl delete deployment "$DEPLOY" -n "$NS" --ignore-not-found=true
  ok "已删除 Deployment/$DEPLOY。命名空间 $NS 里其他资源未受影响。"
}

CLEANUP_ONLY=0
STEPS=()
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP_ONLY=1 ;;
    1|2|3|4|5|6|7|8|9|10) STEPS+=("$arg") ;;
    *) printf '未知参数：%s\n' "$arg"; exit 1 ;;
  esac
done

if [ "$CLEANUP_ONLY" = "1" ]; then cleanup; exit 0; fi
[ "${#STEPS[@]}" -eq 0 ] && STEPS=(1 2 3 4 5 6 7 8 9 10)

if ! command -v kubectl >/dev/null 2>&1; then
  printf '找不到 kubectl。\n'; exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  printf '连不上集群。请先按第 1 章【积木 1-10】起一个集群。\n'; exit 1
fi

printf '\n\033[1;33m本实验会在 %s 命名空间创建/修改 Deployment/%s，结束时自动删除。\033[0m\n' "$NS" "$DEPLOY"
printf '继续？(y/N) '
read -r answer
case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac

want() { for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# ---------------------------------------------------------------------------
if want 1; then
  bold "第 1 步：发布 v1"
  rule
  cmd "kubectl apply -f cases/cloudnote/00-namespace.yaml"
  kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  cmd "kubectl apply -f cases/cloudnote/20-api-deployment.yaml"
  kubectl apply -f "$CASE_DIR/20-api-deployment.yaml" >/dev/null
  wait_ready
  kubectl get pods -n "$NS" -l app="$DEPLOY" -o wide
  printf '\n'
  info "ReplicaSet（注意名字里的哈希——它是 Pod 模板的指纹）："
  kubectl get rs -n "$NS" -o wide
  ok "v1 发布完成。当前只有 1 个 ReplicaSet。"
fi

# ---------------------------------------------------------------------------
if want 2; then
  bold "第 2 步：改环境变量触发一次发布，观察滚动过程"
  rule
  info "开始时间：$(stamp)"
  cmd "kubectl set env deployment/api -n cloudnote VERSION=v2"
  kubectl set env deployment/"$DEPLOY" -n "$NS" VERSION=v2 >/dev/null

  info "滚动过程中每 2 秒采样一次（最多 60 秒）："
  printf '\n  %-10s %-42s %s\n' "时间" "ReplicaSet（DESIRED/CURRENT）" "总 Pod 数"
  printf '  %s\n' "--------------------------------------------------------------------------"
  for _ in $(seq 1 30); do
    rsinfo=$(kubectl get rs -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas}/{.status.replicas} {end}')
    total=$(kubectl get pods -n "$NS" -l app="$DEPLOY" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    printf '  %-10s %-42s %s\n' "$(stamp)" "$rsinfo" "$total"
    ready=$(kubectl get pods -n "$NS" -l app="$DEPLOY" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c '^True$' || true)
    [ "$ready" -ge 2 ] && break
    sleep 2
  done
  wait_ready
  printf '\n'
  info "结束时间：$(stamp)"
  printf '\n'
  info "观察要点："
  info "  · 出现了第二个 ReplicaSet（哈希不同 = 模板不同）"
  info "  · 旧的 ReplicaSet 被缩到 0，但**没有被删除**"
  info "  · 过程中总 Pod 数一度达到 3（replicas 2 + maxSurge 1）"
fi

# ---------------------------------------------------------------------------
if want 3; then
  bold "第 3 步：确认旧的 ReplicaSet 还活着（回滚的物理基础）"
  rule
  kubectl get rs -n "$NS" -o wide
  printf '\n'
  info "各 ReplicaSet 的副本数与所用模板中的 VERSION："
  kubectl get rs -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.spec.template.spec.containers[0].env[0].value}{"\n"}{end}' \
    | sed 's/^/  /'
  printf '\n'
  ok "旧 RS 不是「日志」，它是副本为 0 的真实实体 —— 随时可以扩回来。"
fi

# ---------------------------------------------------------------------------
if want 4; then
  bold "第 4 步：查看版本历史"
  rule
  cmd "kubectl rollout history deployment/api -n cloudnote"
  kubectl rollout history deployment/"$DEPLOY" -n "$NS"
  printf '\n'
  warn "CHANGE-CAUSE 为空是正常的，除非发布时打了注解。"
  info "加上它，半年后的你才知道 revision 3 到底是什么："
  info '  kubectl annotate deployment/api -n cloudnote \'
  info '    kubernetes.io/change-cause="升级到 v2" --overwrite'
fi

# ---------------------------------------------------------------------------
if want 5; then
  bold "第 5 步：制造一个坏版本（镜像 tag 不存在）"
  rule
  cmd "kubectl set image deployment/api -n cloudnote api=nginx:1.27-does-not-exist"
  kubectl set image deployment/"$DEPLOY" -n "$NS" api=nginx:1.27-does-not-exist >/dev/null

  info "等待 15 秒，让它进入 ImagePullBackOff……"
  sleep 15
  printf '\n'
  kubectl get pods -n "$NS" -l app="$DEPLOY" -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,REASON:.status.containerStatuses[0].state.waiting.reason'
  printf '\n'
  info "Deployment 整体状态："
  kubectl get deploy "$DEPLOY" -n "$NS"
  printf '\n'
  ok "关键观察：READY 仍然是 2/2 —— 旧的 2 个 Pod 一个都没少！"
  info "这就是 maxUnavailable: 0 的「安全气囊」作用："
  info "  新 Pod 一直不就绪 → 滚动卡在第 1 步 → 旧 RS 一个副本都不敢缩。"
  printf '\n'
  info "Service 后端列表也没受影响："
  kubectl get endpoints "$DEPLOY" -n "$NS" 2>/dev/null || info "（还没创建 Service，第 6 章会加）"
fi

# ---------------------------------------------------------------------------
if want 6; then
  bold "第 6 步：看一眼「我卡住了」的正式标记"
  rule
  info "等 progressDeadlineSeconds（600 秒）超时太久，这里直接看 Conditions 的当前状态："
  kubectl describe deploy "$DEPLOY" -n "$NS" | sed -n '/Conditions/,$p' | head -12
  printf '\n'
  warn "重要：ProgressDeadlineExceeded 只是打个标记，**不会自动回滚**！"
  info "「以为它会自己回滚，结果卡了一整夜」是常见的生产事故。"
fi

# ---------------------------------------------------------------------------
if want 7; then
  bold "第 7 步：回滚（感受一下有多快）"
  rule
  info "回滚前：$(stamp)"
  kubectl get rs -n "$NS" -o wide
  printf '\n'
  cmd "kubectl rollout undo deployment/api -n cloudnote"
  kubectl rollout undo deployment/"$DEPLOY" -n "$NS"
  wait_ready
  info "回滚后：$(stamp)"
  printf '\n'
  kubectl get pods -n "$NS" -l app="$DEPLOY" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,IMAGE:.spec.containers[0].image'
  printf '\n'
  ok "几乎瞬间完成 —— 因为「回滚」只是把两个 ReplicaSet 的副本数对调。"
  info "不需要重新构建镜像、不需要重跑 CI、镜像层可能都还在节点本地缓存里。"
  printf '\n'
  info "版本历史（注意回滚会记录为一次新事件）："
  kubectl rollout history deployment/"$DEPLOY" -n "$NS"
fi

# ---------------------------------------------------------------------------
if want 8; then
  bold "第 8 步：验证 revisionHistoryLimit 真的在起作用"
  rule
  info "先连续发布 5 次，制造多个历史 ReplicaSet……"
  for i in 3 4 5 6 7; do
    kubectl set env deployment/"$DEPLOY" -n "$NS" VERSION=v$i >/dev/null
    kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=120s >/dev/null 2>&1
  done
  info "当前 ReplicaSet 数量："
  kubectl get rs -n "$NS" --no-headers | wc -l | xargs printf '  %s 个\n'

  cmd "kubectl patch deployment/api -n cloudnote -p '{\"spec\":{\"revisionHistoryLimit\":2}}'"
  kubectl patch deployment/"$DEPLOY" -n "$NS" -p '{"spec":{"revisionHistoryLimit":2}}' >/dev/null
  info "等待控制器清理多余的旧 RS……"
  sleep 12
  printf '\n'
  info "清理后的 ReplicaSet："
  kubectl get rs -n "$NS"
  printf '\n'
  warn "被删掉的旧 RS 意味着：你再也回不到那些版本了。"
  info "所以不要为了「省几个对象」把 revisionHistoryLimit 设小。"
  kubectl patch deployment/"$DEPLOY" -n "$NS" -p '{"spec":{"revisionHistoryLimit":10}}' >/dev/null
fi

# ---------------------------------------------------------------------------
if want 9; then
  bold "第 9 步：观察 maxSurge 的作用"
  rule
  kubectl patch deployment/"$DEPLOY" -n "$NS" -p '{"spec":{"replicas":4}}' >/dev/null
  wait_ready
  info "先扩到 4 个副本，并把 maxSurge 改成 3"

  kubectl patch deployment/"$DEPLOY" -n "$NS" \
    -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":3,"maxUnavailable":0}}}}' >/dev/null

  cmd "kubectl set env deployment/api -n cloudnote VERSION=surge-test"
  kubectl set env deployment/"$DEPLOY" -n "$NS" VERSION=surge-test >/dev/null

  printf '\n  %-10s %s\n' "时间" "总 Pod 数（峰值理论上应该是 4+3=7）"
  printf '  %s\n' "--------------------------------------------------"
  max=0
  for _ in $(seq 1 25); do
    total=$(kubectl get pods -n "$NS" -l app="$DEPLOY" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$total" -gt "$max" ] && max=$total
    printf '  %-10s %s\n' "$(stamp)" "$total"
    ready=$(kubectl get pods -n "$NS" -l app="$DEPLOY" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c '^True$' || true)
    [ "$ready" -ge 4 ] && break
    sleep 2
  done
  wait_ready
  printf '\n'
  ok "观测到的总 Pod 数峰值：$max"
  info "maxSurge 越大 → 并行替换窗口越大 → 发布越快，但峰值资源消耗越高。"
fi

# ---------------------------------------------------------------------------
if want 10; then
  bold "第 10 步：观察 Recreate 策略（会停机）"
  rule
  warn "这一步会让服务短暂完全不可用，注意看总 Pod 数掉到 0 的那一刻。"
  kubectl patch deployment/"$DEPLOY" -n "$NS" -p '{"spec":{"replicas":2}}' >/dev/null
  wait_ready
  kubectl patch deployment/"$DEPLOY" -n "$NS" \
    -p '{"spec":{"strategy":{"type":"Recreate"}}}' >/dev/null
  kubectl set env deployment/"$DEPLOY" -n "$NS" VERSION=recreate-test >/dev/null

  printf '\n  %-10s %s\n' "时间" "总 Pod 数 / 就绪 Pod 数"
  printf '  %s\n' "--------------------------------------------------"
  for _ in $(seq 1 20); do
    total=$(kubectl get pods -n "$NS" -l app="$DEPLOY" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready=$(kubectl get pods -n "$NS" -l app="$DEPLOY" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c '^True$' || true)
    printf '  %-10s %s / %s\n' "$(stamp)" "$total" "$ready"
    [ "$ready" -ge 2 ] && break
    sleep 2
  done
  wait_ready
  printf '\n'
  ok "看到就绪数掉到 0 了吗？这就是 Recreate 的代价 —— 明确的停机。"
  info "什么时候必须用它：应用不支持多版本并存、独占资源（RWO 卷 / 固定主机端口）、有严格启动顺序要求。"
  kubectl patch deployment/"$DEPLOY" -n "$NS" \
    -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}' >/dev/null
fi

cleanup
printf '\n\033[1;32m实验完成。\033[0m对照第 5 章正文【积木 5-6】阅读效果最佳。\n\n'
