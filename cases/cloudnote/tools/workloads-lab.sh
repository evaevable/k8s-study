#!/usr/bin/env bash
# ============================================================================
# 第 13 章动手实验：把四种工作负载都跑一遍
#
# 实验列表：
#   1. StatefulSet 的三个稳定（有序启动 / 独立 PVC / Pod 级 DNS / 重建后名字与存储不变）
#   2. 对比 Deployment 的 Pod 重建（名字变、不知道原来的盘）
#   3. DaemonSet 的「每节点一个」（Pod 数 = 节点数，与 replicas 无关）
#   4. Job：把「一次性动作」声明化（completions 达成即 Complete，幂等）
#   5. Job 的 Indexed 模式（每个 Pod 处理自己的分片）
#   6. CronJob（按时间表产生 Job，而不是直接跑 Pod）
#   7. 清理
#
# 说明：本实验会创建 StatefulSet 及其 PVC，清理时会一并删除这些 PVC。
#
# 用法：
#   bash cases/cloudnote/tools/workloads-lab.sh            # 跑全部
#   bash cases/cloudnote/tools/workloads-lab.sh 1 4 6      # 只跑指定步骤
#   bash cases/cloudnote/tools/workloads-lab.sh --cleanup  # 只做清理
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
  kubectl delete cronjob every-minute -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete job hello-job indexed-job -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete daemonset node-info -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete statefulset postgres -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete svc postgres -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  # StatefulSet 的 PVC 不会被自动删除，必须手动清理
  kubectl delete pvc -n "$NS" -l app=postgres --ignore-not-found=true >/dev/null 2>&1
  ok "已清理 StatefulSet / DaemonSet / Job / CronJob 及其 PVC。"
  info "其他章节的资源（api / web / config 等）未受影响。"
}

CLEANUP_ONLY=0
STEPS=()
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP_ONLY=1 ;;
    1|2|3|4|5|6|7) STEPS+=("$arg") ;;
    *) printf '未知参数：%s\n' "$arg"; exit 1 ;;
  esac
done

if [ "$CLEANUP_ONLY" = "1" ]; then cleanup; exit 0; fi
[ "${#STEPS[@]}" -eq 0 ] && STEPS=(1 2 3 4 5 6 7)

command -v kubectl >/dev/null 2>&1 || { printf '找不到 kubectl。\n'; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { printf '连不上集群。请先按第 1 章【积木 1-10】起一个集群。\n'; exit 1; }

printf '\n\033[1;33m本实验会在 %s 命名空间创建 StatefulSet（含 3 个 PVC，共约 30Gi 声明容量）。\033[0m\n' "$NS"
printf '\033[1;33m清理时会删除这些 PVC —— 本地集群用的是 local-path 供给，会真的释放空间。\033[0m\n'
printf '继续？(y/N) '
read -r answer
case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac

want() { for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

ensure_ns() {
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
}

# ---------------------------------------------------------------------------
if want 1; then
  bold "实验一：StatefulSet 的三个稳定"
  rule
  ensure_ns
  # postgres 需要 api-secret 提供密码
  kubectl get secret api-secret -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/10-config.yaml" >/dev/null

  cmd "kubectl apply -f cases/cloudnote/50-postgres.yaml"
  kubectl apply -f "$CASE_DIR/50-postgres.yaml" >/dev/null 2>&1

  info "观察有序启动（应该看到 0 就绪后才出现 1）……"
  printf '\n  %-10s %s\n' "时间" "postgres Pod 状态"
  printf '  %s\n' "------------------------------------------------------------"
  for _ in $(seq 1 14); do
    line=$(kubectl get pods -n "$NS" -l app=postgres --no-headers 2>/dev/null \
      | awk '{printf "%s(%s) ", $1, $3}')
    printf '  %-10s %s\n' "$(date +%H:%M:%S)" "${line:-（还没创建）}"
    ready=$(kubectl get pods -n "$NS" -l app=postgres \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c '^True$' || true)
    [ "$ready" -ge 3 ] && break
    sleep 10
  done
  printf '\n'
  kubectl get pods -n "$NS" -l app=postgres | sed 's/^/    /'
  printf '\n'
  ok "有序启动生效：每个 Pod 都要等前一个 Ready 才创建下一个。"
  info "为什么需要：数据库主从、Kafka、ZooKeeper 这类系统的成员必须「逐个加入」。"
  printf '\n'
  info "① 稳定存储 —— 每个 Pod 有自己独立的 PVC（命名规则：data-postgres-<序号>）："
  kubectl get pvc -n "$NS" -l app=postgres | sed 's/^/    /'
  printf '\n'
  info "② 稳定网络身份 —— 每个 Pod 有自己的 DNS 名："
  kubectl run -it --rm dns-probe -n "$NS" --image=busybox:1.36 --restart=Never \
    --command -- sh -c 'echo "--- 单个 Pod 的域名 ---"; nslookup postgres-0.postgres.cloudnote.svc.cluster.local 2>&1 | tail -4; echo "--- headless Service（返回全部 Pod IP）---"; nslookup postgres.cloudnote.svc.cluster.local 2>&1 | tail -6' 2>/dev/null | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
if want 2; then
  bold "实验二：StatefulSet vs Deployment —— Pod 重建后的差别（最关键的一步）"
  rule
  info "① StatefulSet：删掉 postgres-1，看名字和存储是否不变"
  PVC_BEFORE=$(kubectl get pod postgres-1 -n "$NS" -o jsonpath='{.spec.volumes[0].persistentVolumeClaim.claimName}' 2>/dev/null)
  info "   删之前 postgres-1 挂的 PVC：${PVC_BEFORE:-（Pod 不存在）}"
  kubectl delete pod postgres-1 -n "$NS" --wait=false >/dev/null 2>&1
  info "   等待重建……"
  for _ in $(seq 1 12); do
    st=$(kubectl get pod postgres-1 -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$st" = "Running" ] && break
    sleep 5
  done
  PVC_AFTER=$(kubectl get pod postgres-1 -n "$NS" -o jsonpath='{.spec.volumes[0].persistentVolumeClaim.claimName}' 2>/dev/null)
  kubectl get pods -n "$NS" -l app=postgres | sed 's/^/    /'
  printf '\n'
  if [ "$PVC_BEFORE" = "$PVC_AFTER" ] && [ -n "$PVC_AFTER" ]; then
    ok "postgres-1 重建后：名字还是 postgres-1，挂的还是 $PVC_AFTER —— 【数据没丢、身份没变】"
  else
    info "重建后挂的 PVC：$PVC_AFTER"
  fi
  printf '\n'
  info "② 对比 Deployment：删掉一个 api Pod，看名字变不变"
  kubectl get deployment api -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/20-api-deployment.yaml" >/dev/null 2>&1
  DPOD=$(kubectl get pods -n "$NS" -l app=api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  info "   删之前：$DPOD"
  kubectl delete pod "$DPOD" -n "$NS" --wait=false >/dev/null 2>&1
  sleep 15
  kubectl get pods -n "$NS" -l app=api | sed 's/^/    /'
  printf '\n'
  printf '    %-14s %-30s %s\n' "工作负载" "Pod 重建后" "存储"
  printf '    %s\n' "------------------------------------------------------------------"
  printf '    %-14s %-30s %s\n' "StatefulSet" "名字不变（postgres-1）" "挂回原来那个 PVC"
  printf '    %-14s %-30s %s\n' "Deployment" "名字全新（随机后缀）" "不知道原来用的是哪块盘"
  printf '\n'
  ok "这是 StatefulSet 与 Deployment 最本质的差别。"
  printf '\n'
  info "③ 顺便验证：删除 StatefulSet 【不会】删除 PVC"
  warn "下一步会演示，但那会删掉 StatefulSet。如果你想保留，跳过这一小步。"
  kubectl get pvc -n "$NS" -l app=postgres | sed 's/^/    /'
  info "   即使执行 kubectl delete statefulset postgres，上面这三个 PVC 依然会留在集群里"
  info "   （刻意的保护：防止手一抖删库顺便把数据删了）。要清理必须手动删 PVC。"
fi

# ---------------------------------------------------------------------------
if want 3; then
  bold "实验三：DaemonSet ——「每节点一个」不是「总共 N 个」"
  rule
  ensure_ns
  kubectl delete daemonset node-info -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  sleep 3
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-info
  namespace: cloudnote
spec:
  selector:
    matchLabels:
      app: node-info
  template:
    metadata:
      labels:
        app: node-info
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: info
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              echo "我运行在节点：$NODE_NAME"
              echo "节点 IP：$NODE_IP"
              sleep 3600
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef: { fieldPath: spec.nodeName }
            - name: NODE_IP
              valueFrom:
                fieldRef: { fieldPath: status.hostIP }
          resources:
            requests: { cpu: 10m, memory: 16Mi }
EOF
  sleep 15
  printf '\n'
  info "① DaemonSet 的 Pod 分布（每个节点一个）："
  kubectl get pods -n "$NS" -l app=node-info -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' | sed 's/^/    /'
  printf '\n'
  NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  DSRUN=$(kubectl get pods -n "$NS" -l app=node-info --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf '    集群节点数：%s　　DaemonSet 的 Pod 数：%s\n' "$NODES" "$DSRUN"
  printf '\n'
  ok "DaemonSet 的 Pod 数由【节点数】决定，而不是你指定的某个数字。"
  printf '\n'
  info "② 每个 Pod 知道自己在哪个节点上（用了 fieldRef 注入）："
  P=$(kubectl get pods -n "$NS" -l app=node-info -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  kubectl logs "$P" -n "$NS" 2>/dev/null | sed 's/^/    /'
  printf '\n'
  info "③ 对比 Deployment 的 Pod 数由 replicas 决定（与节点数无关）："
  kubectl get deploy api -n "$NS" -o jsonpath='{"    api 的 replicas = "}{.spec.replicas}{"\n"}' 2>/dev/null
  kubectl get deployment api -n "$NS" >/dev/null 2>&1 || info "    （api Deployment 还没创建，跳过对比）"
  printf '\n'
  ok "这就是为什么「用 Deployment 代替 DaemonSet」会在节点扩容后丢掉新节点的日志。"
fi

# ---------------------------------------------------------------------------
if want 4; then
  bold "实验四：Job —— 把「一次性动作」声明化"
  rule
  ensure_ns
  kubectl delete job hello-job -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  sleep 3
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: hello-job
  namespace: cloudnote
spec:
  completions: 1
  parallelism: 1
  backoffLimit: 2
  activeDeadlineSeconds: 120
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: task
          image: busybox:1.36
          command: ["sh", "-c", "echo '执行一次性任务（比如发一封邮件）'; sleep 5; echo '任务完成'"]
          resources:
            requests: { cpu: 10m, memory: 16Mi }
EOF
  info "观察 COMPLETIONS 从 0/1 变成 1/1："
  printf '\n  %-10s %s\n' "时间" "Job 状态"
  printf '  %s\n' "--------------------------------------------------"
  for _ in $(seq 1 10); do
    st=$(kubectl get job hello-job -n "$NS" --no-headers 2>/dev/null | awk '{printf "COMPLETIONS=%-8s DURATION=%s", $2, $3}')
    printf '  %-10s %s\n' "$(date +%H:%M:%S)" "${st:-...}"
    sleep 5
  done
  printf '\n'
  kubectl get job hello-job -n "$NS" | sed 's/^/    /'
  printf '\n'
  ok "Job 的「期望状态」不是「执行某个动作」，而是 status.succeeded == spec.completions"
  info "  这个状态可以被【持续维持】，所以再调谐 100 次也不会重复执行 —— 这就是幂等。"
  printf '\n'
  info "Job 完成后 Pod 还在（默认不清理，方便看日志）："
  kubectl get pods -n "$NS" -l job-name=hello-job | sed 's/^/    /'
  printf '\n'
  info "日志："
  kubectl logs job/hello-job -n "$NS" 2>/dev/null | sed 's/^/    /'
  printf '\n'
  warn "如果没设 ttlSecondsAfterFinished，这些 Completed 的 Pod 会一直留着占 etcd 空间。"
fi

# ---------------------------------------------------------------------------
if want 5; then
  bold "实验五：Job 的 Indexed 模式（分片任务）"
  rule
  ensure_ns
  kubectl delete job indexed-job -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  sleep 3
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: indexed-job
  namespace: cloudnote
spec:
  completions: 5
  parallelism: 3
  completionMode: Indexed
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: shard
          image: busybox:1.36
          command:
            - sh
            - -c
            - 'echo "我负责第 $JOB_COMPLETION_INDEX 个分片"; sleep 8'
          resources:
            requests: { cpu: 10m, memory: 16Mi }
EOF
  info "completions=5, parallelism=3 → 同时最多跑 3 个，总共要成功 5 个"
  sleep 25
  printf '\n'
  info "① Pod 与状态："
  kubectl get pods -n "$NS" -l job-name=indexed-job -o custom-columns='POD:.metadata.name,STATUS:.status.phase' | sed 's/^/    /'
  printf '\n'
  info "② 每个 Pod 通过 \$JOB_COMPLETION_INDEX 拿到自己的分片编号："
  for p in $(kubectl get pods -n "$NS" -l job-name=indexed-job -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    printf '    %-26s ' "$p"
    kubectl logs "$p" -n "$NS" 2>/dev/null | head -1
  done
  printf '\n'
  ok "这就是「100 个分片的数据迁移」这类任务的标准做法：每个 Pod 处理一个分片，互不干扰。"
fi

# ---------------------------------------------------------------------------
if want 6; then
  bold "实验六：CronJob —— 按时间表产生 Job"
  rule
  ensure_ns
  kubectl delete cronjob every-minute -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  sleep 2
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: every-minute
  namespace: cloudnote
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 300
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: tick
              image: busybox:1.36
              command: ["sh", "-c", "echo \"定时任务触发于 $(date)\"; sleep 5"]
              resources:
                requests: { cpu: 10m, memory: 16Mi }
EOF
  printf '\n'
  info "CronJob 自己不跑 Pod，它按时间表【产生 Job】，Job 再产生 Pod。"
  info "等触发一次（最多 90 秒）……"
  printf '\n'
  for _ in $(seq 1 10); do
    n=$(kubectl get jobs -n "$NS" --no-headers 2>/dev/null | grep -c every-minute || true)
    printf '  %-10s 已产生的 Job 数：%s\n' "$(date +%H:%M:%S)" "$n"
    [ "$n" -ge 1 ] && break
    sleep 10
  done
  printf '\n'
  info "① CronJob："
  kubectl get cronjob every-minute -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "② 它产生的 Job（注意名字里带时间戳）："
  kubectl get jobs -n "$NS" 2>/dev/null | grep -E "NAME|every-minute" | sed 's/^/    /'
  printf '\n'
  info "③ Job 产生的 Pod："
  kubectl get pods -n "$NS" 2>/dev/null | grep -E "NAME|every-minute" | sed 's/^/    /' || info "    （还没产生或已被 ttl 清理）"
  printf '\n'
  ok "关键观察：CronJob → Job → Pod，这是三层对象。"
  printf '\n'
  warn "三个必须知道的坑："
  info "  ① 默认时区是 UTC！要按北京时间跑必须写 timeZone: Asia/Shanghai"
  info "  ② concurrencyPolicy 默认是 Allow（可能叠加运行），备份类任务应该用 Forbid"
  info "  ③ 可能重复执行或补跑错过的轮次 —— 所以任务必须是幂等的（第 4 章）"
fi

# ---------------------------------------------------------------------------
if want 7; then
  bold "实验七：清理"
  rule
  cleanup
fi

printf '\n\033[1;32m实验完成。\033[0m对照第 13 章正文【积木 13-9】阅读效果最佳。\n\n'
