#!/usr/bin/env bash
# ============================================================================
# 第 14 章实战总演习：CloudNote 五阶段部署 + 13 项验收 + 六个故障演习
#
# 用法：
#   bash cases/cloudnote/tools/capstone-lab.sh deploy           # 五阶段部署
#   bash cases/cloudnote/tools/capstone-lab.sh verify           # 13 项验收检查
#   bash cases/cloudnote/tools/capstone-lab.sh fault            # 跑全部故障演习
#   bash cases/cloudnote/tools/capstone-lab.sh fault 3          # 只跑第 3 个演习
#   bash cases/cloudnote/tools/capstone-lab.sh cleanup          # 全部清理
#   bash cases/cloudnote/tools/capstone-lab.sh kustomize        # 用 kubectl apply -k 一把梭
#
# 故障演习清单：
#   1. 删掉主库 Pod —— 数据会丢吗
#   2. 发一个坏版本，然后回滚
#   3. 探针配错导致全站不可用（第 11 章那个事故）
#   4. 节点污点：NoSchedule vs NoExecute
#   5. 打满流量，看 HPA 扩不上去
#   6. K8s 救不了的三种故障（配置错 / 业务错 / 数据误删）
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
bad()  { printf '\033[1;31m  %s\033[0m\n' "$1"; }

TAINTED_NODE=""
resume_taint() {
  if [ -n "$TAINTED_NODE" ]; then
    kubectl taint nodes "$TAINTED_NODE" maintenance=true:NoSchedule- >/dev/null 2>&1
    kubectl taint nodes "$TAINTED_NODE" maintenance=true:NoExecute- >/dev/null 2>&1
  fi
}
trap resume_taint EXIT

apply_f() { kubectl apply -f "$CASE_DIR/$1" >/dev/null 2>&1; }
wait_deploy() { kubectl rollout status deployment/"$1" -n "$NS" --timeout=180s >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
cleanup() {
  bold "清理 CloudNote 全部资源"
  resume_taint
  kubectl delete pod load-gen net-probe dns-probe -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/40-ingress.yaml" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/60-hpa.yaml" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/35-worker.yaml" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/30-web.yaml" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/22-api-service.yaml" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/20-api-deployment.yaml" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/50-postgres.yaml" --ignore-not-found=true >/dev/null 2>&1
  # StatefulSet 的 PVC 不会被自动删除，必须手动清理（第 13 章）
  kubectl delete pvc -n "$NS" -l app=postgres --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/10-config.yaml" --ignore-not-found=true >/dev/null 2>&1
  ok "已清理。命名空间 cloudnote 本身保留（如需删除：kubectl delete ns cloudnote）"
  info "注意：如果集群里装过 metrics-server / Ingress Controller，那是集群级组件，不会删除。"
}

# ---------------------------------------------------------------------------
deploy() {
  bold "阶段一：地基（命名空间 + 配置 + 密钥）"
  rule
  cmd "kubectl apply -f cases/cloudnote/00-namespace.yaml"
  apply_f "00-namespace.yaml"
  kubectl get ns "$NS" 2>/dev/null | sed 's/^/    /'
  cmd "kubectl apply -f cases/cloudnote/10-config.yaml"
  apply_f "10-config.yaml"
  kubectl get configmap,secret -n "$NS" 2>/dev/null | sed 's/^/    /'
  printf '\n'
  info "检查：Secret 里的密码是 base64 的（不是加密！）"
  kubectl get secret api-secret -n "$NS" -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null | sed 's/^/    /'
  printf '\n'
  warn "生产上必须确认：这个 Secret 不是以明文 YAML 提交在 Git 里的。"

  bold "阶段二：数据层（headless Service + StatefulSet）"
  rule
  cmd "kubectl apply -f cases/cloudnote/50-postgres.yaml"
  apply_f "50-postgres.yaml"
  info "等待有序启动（0 就绪才建 1）……"
  for _ in $(seq 1 24); do
    ready=$(kubectl get pods -n "$NS" -l app=postgres \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c '^True$' || true)
    [ "$ready" -ge 3 ] && break
    sleep 5
  done
  printf '\n'
  kubectl get pods -n "$NS" -l app=postgres 2>/dev/null | sed 's/^/    /'
  printf '\n'
  info "每个 Pod 的独立 PVC："
  kubectl get pvc -n "$NS" 2>/dev/null | sed 's/^/    /'
  printf '\n'
  info "如果 PVC 一直 Pending —— 检查 StorageClass 的 volumeBindingMode"
  info "  WaitForFirstConsumer 时，PVC 会等第一个用到它的 Pod 被调度后才创建卷（第 9 章）"

  bold "阶段三：应用层（api / web / worker + Service）"
  rule
  apply_f "20-api-deployment.yaml"; apply_f "22-api-service.yaml"
  apply_f "30-web.yaml"; apply_f "35-worker.yaml"
  wait_deploy api; wait_deploy web; wait_deploy worker
  printf '\n'
  kubectl get deploy,pods -n "$NS" 2>/dev/null | sed 's/^/    /'
  printf '\n'
  info "Endpoints 检查（排查 Service 问题的第一站）："
  kubectl get endpoints -n "$NS" 2>/dev/null | sed 's/^/    /'
  printf '\n'
  info "连通性测试（注意：不用 ping！ClusterIP 永远 ping 不通）"
  kubectl run net-probe -n "$NS" --image=busybox:1.36 --restart=Never --rm -it \
    --command -- sh -c 'wget -qO- --timeout=5 http://api:8080 | head -3' 2>/dev/null | sed 's/^/    /'

  bold "阶段四：入口与弹性（Ingress / HPA）"
  rule
  apply_f "40-ingress.yaml"
  kubectl get ingress -n "$NS" 2>/dev/null | sed 's/^/    /'
  printf '\n'
  apply_f "60-hpa.yaml"
  kubectl get hpa,vpa -n "$NS" 2>/dev/null | sed 's/^/    /'
  printf '\n'
  warn "看 TARGETS 列："
  info "  api 显示真实数值 → 正常"
  info "  <unknown> → metrics-server 没装，或容器没写 requests（第 12 章）"
  info "  worker 是 <unknown> 属【预期行为】—— 它用的是 External 指标，需要 adapter"

  bold "阶段五：验收"
  rule
  verify
}

# ---------------------------------------------------------------------------
verify() {
  local pass=0 fail=0
  chk() {  # chk "描述" "结果"  —— 结果为空或 0 视为通过
    if [ -z "$2" ] || [ "$2" = "0" ]; then
      printf '    \033[1;32m✔\033[0m %s\n' "$1"; pass=$((pass+1))
    else
      printf '    \033[1;31m✘\033[0m %s  （%s）\n' "$1" "$2"; fail=$((fail+1))
    fi
  }

  bold "13 项验收检查"
  printf '  %s\n' "------------------------------------------------------------"

  # 1 所有 Pod 就绪
  notready=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$2 !~ /^([0-9]+)\/\1$/ {print $1}' | wc -l | tr -d ' ')
  chk "1. 所有 Pod 就绪（READY 分子=分母）" "$notready"

  # 2 无异常重启
  restarts=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$4+0 > 0 {print $1}' | wc -l | tr -d ' ')
  chk "2. 无异常重启（RESTARTS 全为 0）" "$restarts"

  # 3 无 Pending
  pending=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep -c Pending || true)
  chk "3. 无 Pending" "$pending"

  # 4 Service 都有后端
  noep=$(kubectl get endpoints -n "$NS" --no-headers 2>/dev/null | awk '$2=="<none>" {print $1}' | wc -l | tr -d ' ')
  chk "4. 所有 Endpoints 都有后端" "$noep"

  # 5 PVC 全部 Bound
  pvcpend=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | grep -c -v Bound || true)
  chk "5. PVC 全部 Bound" "$pvcpend"

  # 6 副本打散
  nodes=$(kubectl get pods -n "$NS" -l app=api -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
  replicas=$(kubectl get deploy api -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [ "${nodes:-0}" -ge "${replicas:-1}" ]; then chk "6. api 副本分布于不同节点（$nodes 个节点 / $replicas 个副本）" ""
  else chk "6. api 副本分布于不同节点" "只落在 $nodes 个节点上"; fi

  # 7 探针就位
  probe=$(kubectl get deploy api -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)
  chk "7. api 配置了 readinessProbe" "$([ -z "$probe" ] && echo '未配置')"

  # 8 资源已声明
  res=$(kubectl get deploy api -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.requests}' 2>/dev/null)
  chk "8. api 声明了 resources.requests" "$([ -z "$res" ] && echo '未声明')"

  # 9 QoS 不是 BestEffort
  pod=$(kubectl get pods -n "$NS" -l app=api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  qos=$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.qosClass}' 2>/dev/null)
  chk "9. api 的 QoS 不是 BestEffort（实际：${qos:-未知}）" "$([ "$qos" = "BestEffort" ] && echo '是 BestEffort')"

  # 10 HPA 有指标
  unk=$(kubectl get hpa api -n "$NS" --no-headers 2>/dev/null | grep -c unknown || true)
  chk "10. api 的 HPA 有指标（TARGETS 不是 unknown）" "$unk"

  # 11 Ingress 有地址
  addr=$(kubectl get ingress -n "$NS" --no-headers 2>/dev/null | awk '{print $4}' | head -1)
  chk "11. Ingress 有 ADDRESS（实际：${addr:-空}）" "$([ -z "$addr" ] || [ "$addr" = "<none>" ] && echo '没有地址')"

  # 12 内部访问通
  code=$(kubectl run net-probe -n "$NS" --image=busybox:1.36 --restart=Never --rm -it \
    --command -- sh -c 'wget -qO /dev/null --timeout=5 http://api:8080 && echo 200 || echo FAIL' 2>/dev/null | tr -d '[:space:]')
  chk "12. 集群内可访问 api（$code）" "$([ "$code" = "200" ] && echo '' || echo '不通')"

  # 13 无 Warning 事件
  warns=$(kubectl get events -n "$NS" --field-selector type=Warning --no-headers 2>/dev/null | wc -l | tr -d ' ')
  chk "13. 无 Warning 事件（$warns 条）" "$warns"

  printf '  %s\n' "------------------------------------------------------------"
  printf '  通过 \033[1;32m%s\033[0m 项，失败 \033[1;31m%s\033[0m 项\n' "$pass" "$fail"
  printf '\n'
  if [ "$fail" -gt 0 ]; then
    warn "有失败项。逐条排查建议："
    info "  重启/Pending → kubectl describe pod 看 Events"
    info "  Endpoints 空 → 核对 Service 的 selector 与 Pod 标签"
    info "  PVC 未 Bound → kubectl describe pvc 看 Events；确认 StorageClass"
    info "  探针未配置 → 补上 readinessProbe（第 11 章）"
    info "  TARGETS unknown → 装 metrics-server 或补 requests（第 12 章）"
    info "  Warning 事件 → kubectl get events -n $NS --field-selector type=Warning"
  else
    ok "全部通过。但这只说明「配置对了」—— 不代表业务逻辑对（第 14 章演习六）。"
  fi
}

# ---------------------------------------------------------------------------
fault() {
  local which="${1:-all}"
  ensure_ready() {
    kubectl get deploy api -n "$NS" >/dev/null 2>&1 || { warn "api 还没部署，先跑：$0 deploy"; exit 1; }
  }

  if [ "$which" = "all" ] || [ "$which" = "1" ]; then
    ensure_ready
    bold "演习一：删掉主库 Pod —— 数据会丢吗"
    rule
    kubectl get ns "$NS" >/dev/null 2>&1 || apply_f "00-namespace.yaml"
    kubectl get secret api-secret -n "$NS" >/dev/null 2>&1 || apply_f "10-config.yaml"
    kubectl get sts postgres -n "$NS" >/dev/null 2>&1 || { apply_f "50-postgres.yaml"; sleep 30; }

    info "① 写一条数据"
    kubectl exec postgres-0 -n "$NS" -- psql -U cloudnote -d cloudnote -c \
      "CREATE TABLE IF NOT EXISTS t(id int, note text); DELETE FROM t; INSERT INTO t VALUES (1,'这条数据很重要');" 2>/dev/null | sed 's/^/    /'
    info "② 确认数据在"
    kubectl exec postgres-0 -n "$NS" -- psql -U cloudnote -d cloudnote -c "SELECT * FROM t;" 2>/dev/null | sed 's/^/    /'
    printf '\n'
    info "③ 记住它挂的 PVC：$(kubectl get pod postgres-0 -n "$NS" -o jsonpath='{.spec.volumes[0].persistentVolumeClaim.claimName}' 2>/dev/null)"
    info "④ 删掉 postgres-0 ……"
    kubectl delete pod postgres-0 -n "$NS" --wait=false >/dev/null 2>&1
    for _ in $(seq 1 24); do
      st=$(kubectl get pod postgres-0 -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
      [ "$st" = "Running" ] && break
      sleep 5
    done
    printf '\n'
    info "⑤ 重建后："
    kubectl get pods -n "$NS" -l app=postgres 2>/dev/null | sed 's/^/    /'
    printf '    挂的 PVC：%s\n' "$(kubectl get pod postgres-0 -n "$NS" -o jsonpath='{.spec.volumes[0].persistentVolumeClaim.claimName}' 2>/dev/null)"
    printf '\n'
    info "⑥ 数据还在吗"
    kubectl exec postgres-0 -n "$NS" -- psql -U cloudnote -d cloudnote -c "SELECT * FROM t;" 2>/dev/null | sed 's/^/    /'
    printf '\n'
    ok "Pod 名字不变、PVC 不变、数据还在 —— 这是 StatefulSet 的三个稳定（第 13 章）。"
    warn "但这【不等于】数据库高可用：主库故障时能不能提升从库，StatefulSet 完全不管。"
    info "那需要 Operator 或你手写的自动化。"
  fi

  if [ "$which" = "all" ] || [ "$which" = "2" ]; then
    ensure_ready
    bold "演习二：发一个坏版本，然后回滚"
    rule
    info "① 当前状态："
    kubectl get deploy api -n "$NS" 2>/dev/null | sed 's/^/    /'
    info "② 发坏版本（不存在的镜像 tag）"
    kubectl set image deployment/api -n "$NS" api=nginx:1.27-does-not-exist >/dev/null 2>&1
    info "③ 等 20 秒，观察……"
    sleep 20
    kubectl get pods -n "$NS" -l app=api 2>/dev/null | sed 's/^/    /'
    printf '\n'
    kubectl get deploy api -n "$NS" 2>/dev/null | sed 's/^/    /'
    printf '\n'
    ok "新 Pod 起不来，但 READY 还是 2/2 —— 旧的副本一个都没少。"
    info "这就是 maxUnavailable: 0 的安全气囊作用（第 5 章）。"
    printf '\n'
    info "④ Conditions（「我卡住了」的正式标记）："
    kubectl describe deploy api -n "$NS" 2>/dev/null | sed -n '/Conditions/,$p' | head -8 | sed 's/^/    /'
    printf '\n'
    warn "ProgressDeadlineExceeded 只是打个标记，【不会自动回滚】。"
    printf '\n'
    info "⑤ 回滚"
    kubectl rollout undo deployment/api -n "$NS" >/dev/null 2>&1
    kubectl rollout status deployment/api -n "$NS" --timeout=180s >/dev/null 2>&1
    kubectl get pods -n "$NS" -l app=api 2>/dev/null | sed 's/^/    /'
    printf '\n'
    ok "几乎瞬间完成 —— 因为「回滚」只是把两个 ReplicaSet 的副本数对调（第 5 章）。"
  fi

  if [ "$which" = "all" ] || [ "$which" = "3" ]; then
    ensure_ready
    bold "演习三：一个探针配置，让全站不可用"
    rule
    warn "这一步会让服务真的不可用几十秒，注意观察「全部副本同时失败」。"
    printf '继续？(y/N) '
    read -r a
    if [ "$a" = "y" ] || [ "$a" = "Y" ]; then
      info "把 liveness 探针指向不存在的路径……"
      kubectl patch deployment/api -n "$NS" --type=json -p='[
        {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/does-not-exist"}
      ]' >/dev/null 2>&1
      printf '\n'
      for _ in $(seq 1 8); do
        line=$(kubectl get pods -n "$NS" -l app=api --no-headers 2>/dev/null | awk '{printf "%s(%s,R=%s) ", $1, $3, $4}')
        printf '  %-10s %s\n' "$(date +%H:%M:%S)" "$line"
        sleep 8
      done
      printf '\n'
      ok "关键观察：多个副本【同时】探针失败、【同时】被杀重启。"
      info "因为 liveness 检查的是同一件事 —— 所以效果上等于「一次全量重启」（第 11 章）。"
      printf '\n'
      info "Endpoints 应该已经空了："
      kubectl get endpoints api -n "$NS" 2>/dev/null | sed 's/^/    /'
      printf '\n'
      info "恢复探针……"
      kubectl patch deployment/api -n "$NS" --type=json -p='[
        {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/"}
      ]' >/dev/null 2>&1
      kubectl rollout status deployment/api -n "$NS" --timeout=240s >/dev/null 2>&1
      kubectl get pods -n "$NS" -l app=api 2>/dev/null | sed 's/^/    /'
      printf '\n'
      warn "结论：liveness 探针只能反映「我自己还能不能干活」，绝不能反映「我的依赖是否健康」。"
    else
      info "已跳过。"
    fi
  fi

  if [ "$which" = "all" ] || [ "$which" = "4" ]; then
    ensure_ready
    bold "演习四：节点污点 —— NoSchedule vs NoExecute"
    rule
    TAINTED_NODE=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v control-plane | head -1)
    if [ -z "$TAINTED_NODE" ]; then
      warn "找不到 worker 节点，跳过。"
    else
      info "选中节点：$TAINTED_NODE"
      printf '\n'
      info "① 加 NoSchedule 污点（不赶走已运行的 Pod）"
      kubectl taint nodes "$TAINTED_NODE" maintenance=true:NoSchedule 2>&1 | sed 's/^/    /'
      info "② 触发一次滚动更新，看新 Pod 会不会避开它"
      kubectl rollout restart deployment/api -n "$NS" >/dev/null 2>&1
      sleep 15
      kubectl get pods -n "$NS" -l app=api -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' 2>/dev/null | sed 's/^/    /'
      printf '\n'
      ok "新 Pod 会被调度到没有污点的节点；原节点上已有的 Pod【还在跑】。"
      printf '\n'
      info "③ 改成 NoExecute（会驱逐已运行的 Pod）"
      kubectl taint nodes "$TAINTED_NODE" maintenance=true:NoExecute 2>&1 | sed 's/^/    /'
      sleep 40
      kubectl get pods -n "$NS" -l app=api -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' 2>/dev/null | sed 's/^/    /'
      printf '\n'
      ok "这次原来在那个节点上的 Pod 被【驱逐】了，并在别的节点重建。"
      printf '\n'
      printf '    %-16s %s\n' "effect" "对已运行的 Pod"
      printf '    %s\n' "------------------------------------------"
      printf '    %-16s %s\n' "NoSchedule" "留着不动"
      printf '    %-16s %s\n' "NoExecute" "驱逐"
      printf '\n'
      info "清理污点……"
      kubectl taint nodes "$TAINTED_NODE" maintenance=true:NoExecute- >/dev/null 2>&1
      kubectl taint nodes "$TAINTED_NODE" maintenance=true:NoSchedule- >/dev/null 2>&1
      TAINTED_NODE=""
      ok "污点已移除。"
    fi
  fi

  if [ "$which" = "all" ] || [ "$which" = "5" ]; then
    ensure_ready
    bold "演习五：打满流量，看 HPA 扩不上去"
    rule
    if [ -z "$(kubectl top nodes 2>/dev/null)" ]; then
      warn "metrics-server 没装，HPA 不会有指标。跳过本演习。"
      info "安装方法见第 12 章【积木 12-10】。"
    else
      kubectl get hpa api -n "$NS" >/dev/null 2>&1 || apply_f "60-hpa.yaml"
      info "启动负载……"
      kubectl delete pod load-gen -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
      kubectl run load-gen -n "$NS" --image=busybox:1.36 --restart=Never \
        --command -- sh -c 'while true; do wget -q -O- http://api:8080 >/dev/null 2>&1 || sleep 1; done' >/dev/null 2>&1
      for p in $(kubectl get pods -n "$NS" -l app=api -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        kubectl exec "$p" -n "$NS" -- sh -c 'nohup sh -c "while true; do :; done" >/dev/null 2>&1 &' >/dev/null 2>&1 || true
      done
      printf '\n'
      for _ in $(seq 1 10); do
        h=$(kubectl get hpa api -n "$NS" --no-headers 2>/dev/null | awk '{printf "TARGETS=%-12s REPLICAS=%s", $3, $6}')
        pd=$(kubectl get pods -n "$NS" -l app=api --no-headers 2>/dev/null | grep -c Pending || true)
        printf '  %-10s %-38s Pending=%s\n' "$(date +%H:%M:%S)" "$h" "$pd"
        sleep 15
      done
      printf '\n'
      pd=$(kubectl get pods -n "$NS" -l app=api --no-headers 2>/dev/null | grep -c Pending || true)
      if [ "$pd" -gt 0 ]; then
        warn "有 $pd 个 Pod 卡在 Pending —— 这就是「两个层次的伸缩没接上」。"
        P=$(kubectl get pods -n "$NS" -l app=api --no-headers 2>/dev/null | grep Pending | head -1 | awk '{print $1}')
        kubectl describe pod "$P" -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | head -5 | sed 's/^/    /'
        printf '\n'
        info "HPA 只管「要几个 Pod」，完全不管「节点装不装得下」。"
        info "在云上 Cluster Autoscaler 会加机器（1~3 分钟）；本地集群没有 CA，所以会一直 Pending。"
      else
        ok "没有 Pending —— 集群资源还够，弹性正常工作。"
      fi
      printf '\n'
      info "停止负载……"
      kubectl delete pod load-gen -n "$NS" --wait=false >/dev/null 2>&1
      for p in $(kubectl get pods -n "$NS" -l app=api -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        kubectl exec "$p" -n "$NS" -- sh -c 'pkill -f "while true" 2>/dev/null || true' >/dev/null 2>&1 || true
      done
      info "注意：副本数不会立刻降 —— 缩容有 300 秒观察窗口（第 12 章）。"
    fi
  fi

  if [ "$which" = "all" ] || [ "$which" = "6" ]; then
    ensure_ready
    bold "演习六：K8s 救不了的三种故障"
    rule
    printf '\n'
    info "① 配置错误 —— 它会永远重启下去"
    cmd "kubectl set env deployment/api -n cloudnote DB_HOST=postgres-wrong-host"
    kubectl set env deployment/api -n "$NS" DB_HOST=postgres-wrong-host >/dev/null 2>&1
    sleep 45
    kubectl get pods -n "$NS" -l app=api 2>/dev/null | sed 's/^/    /'
    printf '\n'
    info "观察：CrashLoopBackOff，RESTARTS 一直涨 —— 因为「重启」解决不了「配置错」。"
    kubectl set env deployment/api -n "$NS" DB_HOST- >/dev/null 2>&1
    kubectl rollout status deployment/api -n "$NS" --timeout=240s >/dev/null 2>&1
    printf '\n'
    info "② 业务逻辑故障 —— K8s 会认为一切正常"
    info "   （这里用注释说明，因为演示容器是 nginx，没有真实业务逻辑）"
    printf '    %-34s %s\n' "K8s 看到的" "可能的事实"
    printf '    %s\n' "------------------------------------------------------------"
    printf '    %-34s %s\n' "STATUS=Running" "进程活着"
    printf '    %-34s %s\n' "READY=1/1（探针通过）" "能响应 HTTP"
    printf '    %-34s %s\n' "RESTARTS=0" "没崩溃过"
    printf '    %-34s %s\n' "—— 但接口可能全返回错误 ——" "数据库连不上 / 逻辑 bug"
    printf '\n'
    warn "探针只能证明「我还能响应 HTTP」，证明不了「我返回的结果是对的」。"
    info "所以要补：业务指标监控（QPS / 错误率 / P99）+ 告警。"
    printf '\n'
    info "③ 数据误删 —— K8s 毫无反应"
    kubectl get sts postgres -n "$NS" >/dev/null 2>&1 && {
      kubectl exec postgres-0 -n "$NS" -- psql -U cloudnote -d cloudnote -c "DROP TABLE IF EXISTS t;" 2>/dev/null | sed 's/^/    /'
      sleep 3
      printf '\n'
      info "K8s 的反应："
      kubectl get pods -n "$NS" -l app=postgres 2>/dev/null | sed 's/^/    /'
      printf '\n'
      bad "数据库 Pod 依然 Running、Ready、RESTARTS=0 —— 它完全不知道数据被删了。"
      info "PVC 防不住人为误删（第 9 章红线二）。"
      info "唯一能救你的是：独立于 K8s 存储体系的、且验证过能恢复的备份。"
    } || info "（postgres 未部署，跳过数据误删演示）"
    printf '\n'
    ok "三种故障的共同点：K8s 修的是「进程和容器的存在性」，不是「业务的正确性」。"
  fi
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  deploy)    deploy ;;
  verify)    verify ;;
  fault)     fault "${2:-all}" ;;
  cleanup)   cleanup ;;
  kustomize)
    bold "用 kubectl apply -k 一次性部署"
    rule
    cmd "kubectl apply -k cases/cloudnote/"
    kubectl apply -k "$CASE_DIR/" 2>&1 | sed 's/^/    /'
    printf '\n'
    warn "注意：这不保证启动顺序，也可能不等就绪。"
    info "api 可能先于 postgres 起来 → CrashLoopBackOff，等 postgres 就绪后会自己恢复。"
    info "想看有序部署，用：$0 deploy"
    printf '\n'
    info "等 30 秒后检查："
    sleep 30
    kubectl get pods -n "$NS" 2>/dev/null | sed 's/^/    /'
    ;;
  *)
    bold "第 14 章实战总演习"
    rule
    info "用法："
    printf '    %-46s %s\n' "bash $0 deploy" "五阶段部署（推荐，有序）"
    printf '    %-46s %s\n' "bash $0 verify" "13 项验收检查"
    printf '    %-46s %s\n' "bash $0 fault [1-6]" "故障演习（默认全部）"
    printf '    %-46s %s\n' "bash $0 kustomize" "用 kubectl apply -k 一把梭"
    printf '    %-46s %s\n' "bash $0 cleanup" "全部清理"
    printf '\n'
    info "六个故障演习："
    info "  1. 删掉主库 Pod —— 数据会丢吗"
    info "  2. 发一个坏版本，然后回滚"
    info "  3. 探针配错导致全站不可用"
    info "  4. 节点污点：NoSchedule vs NoExecute"
    info "  5. 打满流量，看 HPA 扩不上去"
    info "  6. K8s 救不了的三种故障"
    ;;
esac

printf '\n'
