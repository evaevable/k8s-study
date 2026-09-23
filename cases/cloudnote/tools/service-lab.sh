#!/usr/bin/env bash
# ============================================================================
# 第 6 章动手实验：把 Service 的每一层都验一遍
#
# 覆盖：Endpoints 自动维护 / DNS 解析 / ping 不通但 curl 通 /
#       负载均衡 / Pod 删除后地址簿更新 / 全部不 Ready 时地址簿变空 /
#       内核 iptables 规则 / NodePort / Headless Service
#
# 全程只操作 cloudnote 命名空间里名为 api 的相关资源，结束自动清理。
#
# 用法：
#   bash cases/cloudnote/tools/service-lab.sh              # 跑全部
#   bash cases/cloudnote/tools/service-lab.sh 3 4 7        # 只跑指定步骤
#   bash cases/cloudnote/tools/service-lab.sh --cleanup    # 只做清理
# ============================================================================
set -uo pipefail

NS="cloudnote"
DEPLOY="api"
SVC="api"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
PROBE="svc-probe"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
cmd()  { printf '\033[2m  $ %s\033[0m\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  %s\033[0m\n' "$1"; }

vip() { kubectl get svc "$SVC" -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null; }

cleanup() {
  bold "清理实验资源"
  kubectl delete pod "$PROBE" -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  kubectl delete svc api-nodeport api-headless -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete svc "$SVC" -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete deployment "$DEPLOY" -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  ok "已清理。命名空间 $NS 里其他资源未受影响。"
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

command -v kubectl >/dev/null 2>&1 || { printf '找不到 kubectl。\n'; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { printf '连不上集群。请先按第 1 章【积木 1-10】起一个集群。\n'; exit 1; }

printf '\n\033[1;33m本实验会在 %s 命名空间创建 api 的 Deployment/Service 与一个临时探针 Pod，结束自动清理。\033[0m\n' "$NS"
printf '继续？(y/N) '
read -r answer
case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac

want() { for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

ensure_stack() {
  kubectl get deployment "$DEPLOY" -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/20-api-deployment.yaml" >/dev/null
  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=180s >/dev/null 2>&1
}

# 在临时 Pod 里跑一条命令（用完即删）
in_probe() {
  kubectl delete pod "$PROBE" -n "$NS" --ignore-not-found=true --wait=true >/dev/null 2>&1
  kubectl run "$PROBE" -n "$NS" --image=busybox:1.36 --restart=Never \
    --command -- sh -c "sleep 3600" >/dev/null 2>&1
  kubectl wait --for=condition=Ready pod/"$PROBE" -n "$NS" --timeout=90s >/dev/null 2>&1
  kubectl exec "$PROBE" -n "$NS" -- sh -c "$1" 2>&1
}

# ---------------------------------------------------------------------------
if want 1; then
  bold "第 1 步：创建 Deployment 与 Service"
  rule
  cmd "kubectl apply -f cases/cloudnote/00-namespace.yaml"
  kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  cmd "kubectl apply -f cases/cloudnote/20-api-deployment.yaml"
  kubectl apply -f "$CASE_DIR/20-api-deployment.yaml" >/dev/null
  cmd "kubectl apply -f cases/cloudnote/22-api-service.yaml"
  kubectl apply -f "$CASE_DIR/22-api-service.yaml" >/dev/null
  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=180s >/dev/null 2>&1
  printf '\n'
  kubectl get pods -n "$NS" -l app="$DEPLOY" -o wide
  printf '\n'
  kubectl get svc "$SVC" -n "$NS"
  printf '\n'
  ok "ClusterIP = $(vip)。记住这个地址：它是一个「不存在于任何网卡上」的虚拟 IP。"
fi

# ---------------------------------------------------------------------------
if want 2; then
  bold "第 2 步：看 Service 背后的地址簿（Endpoints / EndpointSlice）"
  rule
  ensure_stack
  cmd "kubectl get endpoints api -n cloudnote"
  kubectl get endpoints "$SVC" -n "$NS" -o wide
  printf '\n'
  cmd "kubectl get endpointslices -n cloudnote"
  kubectl get endpointslices -n "$NS" 2>/dev/null || info "（当前集群不支持 endpointslices 子命令）"
  printf '\n'
  info "这两行 IP:80 就是此刻真实的、健康的、可被转发的后端。"
  warn "排查 Service 问题的第一站永远是这里：Endpoints 为空 = Service 没找到任何后端。"
  info "最常见原因是 selector 与 Pod 标签不一致，或 Pod 全部 NotReady。"
fi

# ---------------------------------------------------------------------------
if want 3; then
  bold "第 3 步：验证 DNS 解析"
  rule
  ensure_stack
  V=$(vip)
  printf '\n'
  info "① 同命名空间下的短名 api："
  in_probe "nslookup api | tail -4" | sed 's/^/    /'
  printf '\n'
  info "② 完整域名 api.cloudnote.svc.cluster.local："
  in_probe "nslookup api.cloudnote.svc.cluster.local | tail -4" | sed 's/^/    /'
  printf '\n'
  info "③ 解析器配置（注意 search 域与 ndots:5）："
  in_probe "cat /etc/resolv.conf" | sed 's/^/    /'
  printf '\n'
  ok "短名之所以能通，是因为 search 域会自动补全为 api.cloudnote.svc.cluster.local"
  info "nslookup 返回的是 ClusterIP（$V），不是任何 Pod IP —— DNS 只帮你找到 Service。"
fi

# ---------------------------------------------------------------------------
if want 4; then
  bold "第 4 步：验证「ping 不通，但 curl 通」"
  rule
  ensure_stack
  printf '\n'
  info "① ICMP（ping）：预期超时失败"
  in_probe "ping -c 2 -W 2 api; echo \"    ping 退出码=\$?\"" | sed 's/^/    /'
  printf '\n'
  info "② TCP（wget / nc）：预期成功"
  in_probe "wget -qO- --timeout=3 http://api:8080 | head -2; echo \"    wget 退出码=\$?\""
  printf '\n'
  in_probe "nc -zv api 8080; echo \"    nc 退出码=\$?\""
  printf '\n'
  ok "同一个地址，ICMP 失败、TCP 成功。"
  info "原因：ClusterIP 不是真实地址，而是「针对 TCP/UDP 的地址改写规则」。"
  info "kube-proxy 不处理 ICMP，所以 ping 的包没有规则改写目标 → 无人接收。"
  warn "结论：永远不要用 ping 测 Service 通不通，用 curl / nc / telnet。"
fi

# ---------------------------------------------------------------------------
if want 5; then
  bold "第 5 步：观察负载均衡（连续请求 10 次）"
  rule
  ensure_stack
  printf '\n'
  in_probe 'for i in $(seq 1 10); do
    code=$(wget -qO /dev/null --timeout=3 http://api:8080 && echo OK || echo FAIL)
    printf "    第 %2s 次: %s\n" "$i" "$code"
  done'
  printf '\n'
  ok "10 次全部 OK —— 说明两个后端都在被正常转发。"
  info "iptables 模式下的分流是「按概率随机」而非轮询："
  info "  2 个后端时两条规则概率分别是 1/2 和 1/1。"
  info "观察真实分流比例，需要让每个 Pod 返回自己的主机名（本案例用默认 nginx 页面看不出来）。"
fi

# ---------------------------------------------------------------------------
if want 6; then
  bold "第 6 步：删一个 Pod，看地址簿自动更新"
  rule
  ensure_stack
  info "删除前的 Endpoints："
  kubectl get endpoints "$SVC" -n "$NS" -o wide
  printf '\n'
  info "记录开始时间：$(date +%H:%M:%S)"
  kubectl delete pod -n "$NS" -l app="$DEPLOY" --wait=false >/dev/null 2>&1
  for _ in $(seq 1 20); do
    line=$(kubectl get endpoints "$SVC" -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}')
    printf '    %s  Endpoints: %s\n' "$(date +%H:%M:%S)" "${line:-<none>}"
    n=$(echo "$line" | wc -w | tr -d ' ')
    [ "$n" -ge 2 ] && break
    sleep 3
  done
  printf '\n'
  kubectl get endpoints "$SVC" -n "$NS" -o wide
  printf '\n'
  ok "全程你没有碰过 Service 对象 —— 是 endpointslice-controller 在自动维护。"
  info "这就是第 4 章讲的调和循环，只不过这里的「期望」是你的 selector，"
  info "「实际」是集群里 Pod 的当前状态。"
fi

# ---------------------------------------------------------------------------
if want 7; then
  bold "第 7 步：让所有 Pod 都不 Ready，看地址簿变空"
  rule
  ensure_stack
  warn "这一步会把就绪探针指向一个不存在的路径，制造「Running 但 NotReady」。"
  kubectl patch deployment "$DEPLOY" -n "$NS" --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/does-not-exist"}
  ]' >/dev/null 2>&1

  info "等待探针连续失败（约 20 秒）……"
  sleep 25
  printf '\n'
  info "① Pod 状态（注意 READY 列应该变成 0/1）："
  kubectl get pods -n "$NS" -l app="$DEPLOY"
  printf '\n'
  info "② Endpoints（应该变成 <none>）："
  kubectl get endpoints "$SVC" -n "$NS"
  printf '\n'
  info "③ 此时访问 Service："
  in_probe "wget -qO- --timeout=3 http://api:8080 >/dev/null 2>&1; echo \"    连接结果退出码=\$?（非 0 表示连接失败）\""
  printf '\n'
  ok "完整链条：readinessProbe 失败 → Pod 变 NotReady → EndpointSlice 移除它"
  info "          → 内核规则更新 → 流量不再打向它。"
  info "这就是第 5 章说「就绪探针是滚动更新的刹车」的完整解释。"
  printf '\n'
  info "恢复探针路径……"
  kubectl patch deployment "$DEPLOY" -n "$NS" --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}
  ]' >/dev/null 2>&1
  kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=180s >/dev/null 2>&1
  info "恢复后的 Endpoints："
  kubectl get endpoints "$SVC" -n "$NS" -o wide
fi

# ---------------------------------------------------------------------------
if want 8; then
  bold "第 8 步：看内核里的 iptables 规则（ClusterIP 的真身）"
  rule
  cmd "iptables -t nat -L KUBE-SERVICES -n"
  printf '\n'
  NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  if docker exec "$NODE" true >/dev/null 2>&1; then
    docker exec "$NODE" iptables -t nat -L KUBE-SERVICES -n 2>/dev/null | grep -iE "cloudnote|KUBE-SVC" | head -10 | sed 's/^/    /'
    printf '\n'
    info "某个 Service 的转发链（KUBE-SVC-*）："
    docker exec "$NODE" iptables -t nat -S 2>/dev/null | grep -E "KUBE-SVC|KUBE-SEP" | head -12 | sed 's/^/    /'
    printf '\n'
    ok "KUBE-SERVICES 匹配「目标 IP:端口」→ KUBE-SVC-* 按概率选后端 → KUBE-SEP-* 执行 DNAT。"
    info "iptables 模式下分流靠 statistic mode random probability（随机概率，不是轮询）。"
  else
    warn "无法进入节点容器（非 kind 环境或没有 docker 权限）。跳过这一步。"
    info "你可以在任意有 kube-proxy 的节点上手动执行："
    info "  iptables -t nat -L KUBE-SERVICES -n"
    info "  iptables -t nat -L -n | grep -E 'KUBE-SVC|KUBE-SEP'"
  fi
fi

# ---------------------------------------------------------------------------
if want 9; then
  bold "第 9 步：试一下 NodePort"
  rule
  ensure_stack
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api-nodeport
  namespace: cloudnote
spec:
  type: NodePort
  selector:
    app: api
  ports:
    - port: 8080
      targetPort: http
      nodePort: 30080
EOF
  kubectl get svc api-nodeport -n "$NS"
  printf '\n'
  info "PORT(S) 那一列显示 8080:30080/TCP —— 后者就是每个节点上开放的端口。"
  printf '\n'
  if curl -s --max-time 5 http://localhost:30080 >/dev/null 2>&1; then
    ok "从宿主机 http://localhost:30080 访问成功（kind 会把节点端口映射出来）"
    curl -s --max-time 5 http://localhost:30080 | head -2 | sed 's/^/    /'
  else
    info "宿主机访问不通是正常的（取决于集群类型与端口映射方式）。"
    info "在有真实节点的集群里，可以用 http://<任意节点IP>:30080 访问。"
  fi
  printf '\n'
  warn "NodePort 一般只是过渡形态：没人愿意把 http://1.2.3.4:30080 给用户。"
  info "生产做法是 Ingress（第 7 章）或前面挂一个负载均衡器。"
  kubectl delete svc api-nodeport -n "$NS" >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
if want 10; then
  bold "第 10 步：Headless Service 的 DNS 长什么样"
  rule
  ensure_stack
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api-headless
  namespace: cloudnote
spec:
  clusterIP: None
  selector:
    app: api
  ports:
    - port: 8080
      targetPort: http
EOF
  printf '\n'
  kubectl get svc api-headless -n "$NS"
  printf '\n'
  info "对比：普通 Service 的 ClusterIP 是一个虚拟 IP，headless 显示 None。"
  printf '\n'
  info "DNS 查询结果的差异："
  in_probe "echo '  --- 普通 Service（返回 1 个 ClusterIP）---'; nslookup api | tail -4; echo '  --- Headless（返回所有 Pod IP）---'; nslookup api-headless | tail -6"
  printf '\n'
  ok "Headless 的 DNS 不再给你一个虚拟 IP，而是把全部后端 IP 交给你自己选。"
  info "必须用它的场景：StatefulSet（需要知道哪个 IP 是 0 号节点）、"
  info "客户端自己做负载均衡（如 gRPC 长连接）、需要 pod-name.service 形式的稳定域名。"
  kubectl delete svc api-headless -n "$NS" >/dev/null 2>&1
fi

cleanup
printf '\n\033[1;32m实验完成。\033[0m对照第 6 章正文【积木 6-9】阅读效果最佳。\n\n'
