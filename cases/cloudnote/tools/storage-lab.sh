# ============================================================================
# 第 9 章动手实验：PVC 与 emptyDir 的 A/B 对照
#
# 两个 Pod 结构完全相同、挂载点相同，只有「后端存储」不同：
#   data-demo-pvc       → 挂 PVC（动态供给的持久卷）
#   data-demo-emptydir  → 挂 emptyDir（随 Pod 生命周期）
#
# 实验：往两边写文件 → 删掉两个 Pod → 重建 → 再看文件还在不在
#   预期：PVC 那边的文件还在 ✅ / emptyDir 那边的文件没了 ❌
#
# 另外还会观察：Pending→Bound、动态供给的 Events、reclaimPolicy: Delete 的实际效果。
#
# 全程只操作 cloudnote 命名空间里本章创建的对象，结束自动清理。
#
# 用法：
#   bash cases/cloudnote/tools/storage-lab.sh            # 跑全部
#   bash cases/cloudnote/tools/storage-lab.sh 1 2 5      # 只跑指定步骤
#   bash cases/cloudnote/tools/storage-lab.sh --cleanup  # 只做清理
# ============================================================================
set -uo pipefail

NS="cloudnote"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$TOOLS_DIR/.." && pwd)"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
cmd()  { printf '\033[2m  $ %s\033[0m\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  %s\033[0m\n' "$1"; }

cleanup() {
  bold "清理实验资源"
  kubectl delete pod data-demo-pvc data-demo-emptydir -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  kubectl delete pvc data-demo probe-pvc -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  ok "已清理 Pod data-demo-* 与 PVC data-demo / probe-pvc。"
  info "注意：因为这些 StorageClass 是 reclaimPolicy: Delete，删除 PVC 会同时删除底层存储。"
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

printf '\n\033[1;33m本实验会在 %s 命名空间创建一个 PVC 与两个 Pod，结束后可选择清理。\033[0m\n' "$NS"
printf '\033[1;33m注意：默认的 StorageClass 多为 reclaimPolicy: Delete，删除 PVC 会真的删除底层数据。\033[0m\n'
printf '继续？(y/N) '
read -r answer
case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac

want() { for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# ---------------------------------------------------------------------------
if want 1; then
  bold "第 1 步：先看清集群的存储类（重点看 BINDING 和 RECLAIM）"
  rule
  kubectl get storageclass 2>/dev/null
  printf '\n'
  kubectl get storageclass -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDING:.volumeBindingMode' 2>/dev/null
  printf '\n'
  info "两个字段的含义："
  info "  RECLAIM=Delete   → 删除 PVC 时，底层存储和数据一起被删除（生产上对数据库很危险）"
  info "  BINDING=WaitForFirstConsumer → 等第一个用到它的 Pod 被调度后，才在对应节点创建卷"
  printf '\n'
  info "如果 BINDING 显示 Immediate，就解释了那种「Pod 卡在 ContainerCreating、报 volume node affinity conflict」的经典故障。"
  printf '\n'
  info "PV 数量（当前集群已有的）："
  kubectl get pv --no-headers 2>/dev/null | wc -l | xargs printf '  %s 个\n'
fi

# ---------------------------------------------------------------------------
if want 2; then
  bold "第 2 步：创建 A/B 对照环境"
  rule
  kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  cmd "kubectl apply -f cases/cloudnote/45-pvc-demo.yaml"
  kubectl apply -f "$CASE_DIR/45-pvc-demo.yaml"
  printf '\n'
  info "等待 PVC 从 Pending 变 Bound（WaitForFirstConsumer 模式下，需要 Pod 先被调度）……"
  for _ in $(seq 1 30); do
    st=$(kubectl get pvc data-demo -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$st" = "Bound" ] && break
    sleep 2
  done
  printf '\n'
  kubectl get pvc -n "$NS"
  printf '\n'
  info "自动创建的 PV（名字形如 pvc-<uid>，这是动态供给的标志）："
  kubectl get pv 2>/dev/null | grep -E "NAME|pvc-" | sed 's/^/    /'
  printf '\n'
  kubectl wait --for=condition=Ready pod/data-demo-pvc pod/data-demo-emptydir -n "$NS" --timeout=120s >/dev/null 2>&1
  kubectl get pod data-demo-pvc data-demo-emptydir -n "$NS" -o wide
  printf '\n'
  ok "两个 Pod 就绪：结构相同、挂载点相同，只有后端存储不同。"
fi

# ---------------------------------------------------------------------------
if want 3; then
  bold "第 3 步：往两边写入同一份「重要数据」"
  rule
  info "写入 PVC 那边："
  kubectl exec data-demo-pvc -n "$NS" -- sh -c 'echo "这条数据很重要 - 来自 PVC" > /data/important.txt; ls -l /data/' 2>&1 | sed 's/^/    /'
  printf '\n'
  info "写入 emptyDir 那边："
  kubectl exec data-demo-emptydir -n "$NS" -- sh -c 'echo "这条数据很重要 - 来自 emptyDir" > /data/important.txt; ls -l /data/' 2>&1 | sed 's/^/    /'
  printf '\n'
  ok "两边都有 important.txt 了。现在把两个 Pod 都删掉。"
fi

# ---------------------------------------------------------------------------
if want 4; then
  bold "第 4 步：删掉两个 Pod，观察 PVC 是否还在"
  rule
  cmd "kubectl delete pod data-demo-pvc data-demo-emptydir -n cloudnote"
  kubectl delete pod data-demo-pvc data-demo-emptydir -n "$NS" --wait=true >/dev/null 2>&1
  sleep 3
  printf '\n'
  info "Pod（应该都没了）："
  kubectl get pods -n "$NS" 2>/dev/null | grep data-demo | sed 's/^/    /' || info "    （已全部删除）"
  printf '\n'
  info "PVC（关键：应该还在，状态 Bound）："
  kubectl get pvc -n "$NS" | sed 's/^/    /'
  printf '\n'
  ok "PVC 不是 Pod 的附属物 —— 它有自己的生命周期，所以能跨越 Pod 重建。"
  info "而 emptyDir 背后的临时目录，随 Pod 一起消失了。"
fi

# ---------------------------------------------------------------------------
if want 5; then
  bold "第 5 步：重建两个 Pod，对比数据命运（本章最关键的一步）"
  rule
  cmd "kubectl apply -f cases/cloudnote/45-pvc-demo.yaml"
  kubectl apply -f "$CASE_DIR/45-pvc-demo.yaml" >/dev/null
  kubectl wait --for=condition=Ready pod/data-demo-pvc pod/data-demo-emptydir -n "$NS" --timeout=120s >/dev/null 2>&1
  printf '\n'
  info "① PVC 那边："
  kubectl exec data-demo-pvc -n "$NS" -- sh -c 'ls -l /data/; echo "--- 文件内容 ---"; cat /data/important.txt 2>/dev/null || echo "（文件不存在）"' 2>&1 | sed 's/^/    /'
  printf '\n'
  info "② emptyDir 那边："
  kubectl exec data-demo-emptydir -n "$NS" -- sh -c 'ls -l /data/; echo "--- 文件内容 ---"; cat /data/important.txt 2>/dev/null || echo "（文件不存在）"' 2>&1 | sed 's/^/    /'
  printf '\n'
  printf '    %-24s %s\n' "Pod" "/data/important.txt"
  printf '    %s\n' "------------------------------------------------------------"
  printf '    %-24s %s\n' "data-demo-pvc（PVC）" "还在 ✅"
  printf '    %-24s %s\n' "data-demo-emptydir" "不存在 ❌"
  printf '\n'
  ok "这一个对比，就是「持久化」这三个字的全部含义。"
  printf '\n'
  info "也可以直接看启动日志（两个 Pod 启动时都会列出 /data 的内容）："
  info "  kubectl logs data-demo-pvc -n $NS"
  info "  kubectl logs data-demo-emptydir -n $NS"
fi

# ---------------------------------------------------------------------------
if want 6; then
  bold "第 6 步：观察动态供给的 Events（理解 Pending 是在等什么）"
  rule
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: probe-pvc
  namespace: cloudnote
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
EOF
  info "刚创建的 probe-pvc 状态："
  kubectl get pvc probe-pvc -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "它的 Events："
  kubectl describe pvc probe-pvc -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | sed 's/^/    /'
  printf '\n'
  ok "看到 Waiting for first consumer 了吗？这就是 WaitForFirstConsumer 在工作 ——"
  info "它在等一个 Pod 来「决定」卷该建在哪个节点。"
  info "所以「单独建 PVC、没有 Pod 用它 → 一直 Pending」不是故障，是设计。"
fi

# ---------------------------------------------------------------------------
if want 7; then
  bold "第 7 步：验证扩容（只能变大，不能变小）"
  rule
  PROBE_ST=$(kubectl get pvc probe-pvc -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ -z "$PROBE_ST" ]; then
    warn "probe-pvc 不存在，先跑第 6 步。跳过。"
  else
    info "当前容量：$(kubectl get pvc probe-pvc -n "$NS" -o jsonpath='{.status.capacity.storage}' 2>/dev/null)"
    printf '\n'
    info "尝试扩到 2Gi："
    kubectl patch pvc probe-pvc -n "$NS" -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' 2>&1 | sed 's/^/    /'
    sleep 3
    printf '\n'
    info "扩容后："
    kubectl get pvc probe-pvc -n "$NS" | sed 's/^/    /'
    printf '\n'
    info "想缩小会怎样（预期被 API Server 拒绝）："
    kubectl patch pvc probe-pvc -n "$NS" -p '{"spec":{"resources":{"requests":{"storage":"1Gi"}}}}' 2>&1 | head -3 | sed 's/^/    /'
    printf '\n'
    ok "扩容是单向的：只能变大。想缩小只能新建 PVC 再迁移数据。"
  fi
fi

# ---------------------------------------------------------------------------
if want 8; then
  bold "第 8 步：认识 reclaimPolicy: Delete 的威力（危险演示）"
  rule
  warn "这一步会真的删除 PVC，并触发底层存储回收。如果 rehearsal 里有生产数据，千万别做。"
  printf '继续第 8 步？(y/N) '
  read -r answer
  if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
    info "已跳过第 8 步。"
  else
    info "删除前的 PV："
    kubectl get pv 2>/dev/null | grep -E "NAME|pvc-" | sed 's/^/    /'
    printf '\n'
    cmd "kubectl delete pvc data-demo -n cloudnote"
    kubectl delete pvc data-demo -n "$NS" >/dev/null 2>&1
    sleep 5
    printf '\n'
    info "删除后的 PV："
    if kubectl get pv 2>/dev/null | grep -q "pvc-"; then
      kubectl get pv 2>/dev/null | grep "pvc-" | sed 's/^/    /'
    else
      printf '    （没有 pvc- 开头的 PV 了）\n'
    fi
    printf '\n'
    warn "PV 消失了 = 底层存储被真正删除 = 数据没了。"
    info "这就是 reclaimPolicy: Delete（动态供给的默认值）的后果。"
    printf '\n'
    ok "结论：数据库必须用 reclaimPolicy: Retain 的 StorageClass，并且要有独立于 K8s 的备份。"
    printf '\n'
    info "对比 Retain 的行为（想体验可以自己建一个 Retain 的 StorageClass 再跑一遍）："
    info "  PVC 删除后，PV 会保留、状态变为 Released，数据仍在，需要人工清理才能复用。"
  fi
fi

printf '\n'
printf '\033[1;33m是否清理本次实验创建的资源？(y/N) \033[0m'
read -r answer
case "$answer" in y|Y) cleanup ;; *) info "保留现场。随时可用 --cleanup 清理。" ;; esac

printf '\n\033[1;32m实验完成。\033[0m对照第 9 章正文【积木 9-10】阅读效果最佳。\n\n'
