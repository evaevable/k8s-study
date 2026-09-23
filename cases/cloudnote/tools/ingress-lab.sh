#!/usr/bin/env bash
# ============================================================================
# 第 7 章动手实验：搭一个七层入口
#
# 步骤：检测控制器 → 部署 web/api → 创建 Ingress → 测路径分流 →
#       验证 Prefix 匹配边界 → 配 TLS
#
# 设计原则：脚本不会擅自安装控制器（那会影响整个集群），只做检测 + 引导。
#           全程只操作 cloudnote 命名空间里的 web / api / Ingress 及其证书。
#
# 用法：
#   bash cases/cloudnote/tools/ingress-lab.sh            # 跑全部
#   bash cases/cloudnote/tools/ingress-lab.sh 1 2 3      # 只跑指定步骤
#   bash cases/cloudnote/tools/ingress-lab.sh --cleanup  # 只做清理
# ============================================================================
set -uo pipefail

NS="cloudnote"
HOSTNAME_DEMO="note.example.com"
LOCAL_HTTP_PORT=18080
LOCAL_HTTPS_PORT=18443
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
REPO_DIR="$(cd "$TOOLS_DIR/../../../.." && pwd)"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
cmd()  { printf '\033[2m  $ %s\033[0m\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  %s\033[0m\n' "$1"; }

cleanup() {
  bold "清理实验资源"
  kubectl delete ingress cloudnote -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete secret cloudnote-tls -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/30-web.yaml" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/22-api-service.yaml" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete -f "$CASE_DIR/20-api-deployment.yaml" --ignore-not-found=true >/dev/null 2>&1
  rm -f /tmp/lab-tls.key /tmp/lab-tls.crt
  pkill -f "port-forward.*$NS" >/dev/null 2>&1
  ok "已清理 cloudnote 里的 web / api / Ingress / 证书。"
  info "Ingress Controller 本身保留不动（它属于整个集群，不属于本实验）。"
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

want() { for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# 找到控制器所在命名空间与 Service（用于 port-forward）
find_controller_svc() {
  kubectl get svc -A -o json 2>/dev/null | /opt/anaconda3/bin/python3 -c "
import json,sys
d=json.load(sys.stdin)
pat=('traefik','contour','envoy','ingress')
for it in d['items']:
    n=it['metadata']['name'].lower()
    ns=it['metadata']['namespace']
    if any(p in n for p in pat) and ns not in ('kube-system','kube-public'):
        print(ns+'/'+it['metadata']['name'])
        break
"
}

# ---------------------------------------------------------------------------
if want 1; then
  bold "第 1 步：检测集群里有没有 Ingress Controller"
  rule
  info "① IngressClass："
  if ! kubectl get ingressclass 2>/dev/null | tail -n +2 | grep -q .; then
    warn "没有找到任何 IngressClass —— 说明集群里没有装 Ingress Controller。"
    printf '\n'
    warn "重要：Ingress 只是「声明」，没有控制器它就是一纸空文。"
    printf '\n'
    info "2026 年的推荐（新装请选仍在维护的控制器）："
    printf '\n'
    info "  【推荐】Traefik（一条 Helm 命令，同时支持 Ingress 和 Gateway API）："
    info "    helm repo add traefik https://traefik.github.io/charts && helm repo update"
    info "    helm install traefik traefik/traefik -n traefik --create-namespace \\"
    info "      --set ingressClass.enabled=true --set ingressClass.isDefaultClass=true"
    printf '\n'
    info "  【替代】Contour / Envoy Gateway / 云厂商自带的（ALB、CLB 等）"
    printf '\n'
    warn "【不要新装】ingress-nginx —— 已于 2026-03 退役，不再有安全补丁。"
    info "  检查是否已经中招：kubectl get pods -A --selector app.kubernetes.io/name=ingress-nginx"
    printf '\n'
    info "装好控制器后重新跑本步骤。"
    exit 1
  else
    kubectl get ingressclass
    ok "找到 IngressClass，可以继续。"
  fi
  printf '\n'
  info "② 控制器 Pod："
  kubectl get pods -A 2>/dev/null | grep -iE "traefik|contour|envoy|ingress-nginx|ingress" | sed 's/^/    /' || info "（--all-namespaces 权限不足）"
  printf '\n'
  info "③ 控制器自己的 Service（注意它也是靠 Service 暴露给外部的——第 6 章的自举结构）："
  CSVC=$(find_controller_svc)
  if [ -n "$CSVC" ]; then
    printf '    %s\n' "$CSVC"
    info "port-forward 时就用它。"
  else
    info "（未自动识别到，请手动找：kubectl get svc -A | grep -iE 'traefik|contour|envoy'）"
  fi
  printf '\n'
  warn "检查是否在用已退役的 ingress-nginx："
  kubectl get pods -A --selector app.kubernetes.io/name=ingress-nginx 2>/dev/null | tail -n +2 | sed 's/^/    /' || true
  info "如果上面有输出，说明你正在用已退役的控制器，应当规划迁移到 Gateway API 或其他控制器。"
fi

# ---------------------------------------------------------------------------
if want 2; then
  bold "第 2 步：部署 web 与 api 两个应用"
  rule
  kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  kubectl apply -f "$CASE_DIR/20-api-deployment.yaml" >/dev/null
  kubectl apply -f "$CASE_DIR/22-api-service.yaml" >/dev/null
  kubectl apply -f "$CASE_DIR/30-web.yaml" >/dev/null
  kubectl rollout status deployment/api -n "$NS" --timeout=180s >/dev/null 2>&1
  kubectl rollout status deployment/web -n "$NS" --timeout=180s >/dev/null 2>&1
  printf '\n'
  kubectl get deploy,svc -n "$NS"
  printf '\n'
  info "两个后端就绪：web -> :80，api -> :8080（由 Ingress 按路径分流）"
fi

# ---------------------------------------------------------------------------
if want 3; then
  bold "第 3 步：创建 Ingress"
  rule
  cmd "kubectl apply -f cases/cloudnote/40-ingress.yaml"
  kubectl apply -f "$CASE_DIR/40-ingress.yaml"
  printf '\n'
  kubectl get ingress -n cloudnote
  printf '\n'
  info "重点看 ADDRESS 那一列："
  info "  有地址   → 控制器已接手"
  info "  <none>   → 控制器没装 / 类名不匹配 / 没有默认 IngressClass"
  printf '\n'
  info "Events 里通常写明被哪个控制器接管了："
  kubectl describe ingress cloudnote -n "$NS" 2>/dev/null | sed -n '/Events/,$p' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
if want 4; then
  bold "第 4 步：测路径分流（用 port-forward + Host 头）"
  rule
  CSVC=$(find_controller_svc)
  if [ -z "$CSVC" ]; then
    warn "没找到控制器的 Service，跳过。请手动执行："
    info "  kubectl get svc -A | grep -iE 'traefik|contour|envoy'"
    info "  kubectl port-forward -n <ns> svc/<name> ${LOCAL_HTTP_PORT}:80"
  else
    info "把控制器 Service $CSVC 的 80 端口转发到本地 ${LOCAL_HTTP_PORT}"
    kubectl port-forward -n "${CSVC%%/*}" "svc/${CSVC##*/}" "${LOCAL_HTTP_PORT}:80" >/dev/null 2>&1 &
    PF_PID=$!
    sleep 4

    printf '\n  %-46s %s\n' "请求" "结果"
    printf '  %s\n' "--------------------------------------------------------------"

    code_root=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOSTNAME_DEMO" "http://localhost:${LOCAL_HTTP_PORT}/" 2>/dev/null)
    printf '  %-46s %s\n' "Host: $HOSTNAME_DEMO  GET /" "$code_root"

    code_api=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOSTNAME_DEMO" "http://localhost:${LOCAL_HTTP_PORT}/api" 2>/dev/null)
    printf '  %-46s %s\n' "Host: $HOSTNAME_DEMO  GET /api" "$code_api"

    code_bad=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: wrong.example.com" "http://localhost:${LOCAL_HTTP_PORT}/" 2>/dev/null)
    printf '  %-46s %s\n' "Host: wrong.example.com  GET /" "$code_bad"

    printf '\n'
    ok "三个都是 200 → 域名规则与两条路径规则都生效了。"
    info "第三个应该也是 200 或 404 —— 取决于控制器对「未匹配 host」的默认处理；"
    info "如果返回的不是业务页面，说明 host 规则确实起了作用（不是被兜底规则吃掉）。"
    printf '\n'
    info "看日志确认流量真的落到了不同的 Pod："
    info "  kubectl logs -n $NS -l app=api --tail=5"
    info "  kubectl logs -n $NS -l app=web --tail=5"
    printf '\n'
    info "port-forward 仍在后台运行（PID $PF_PID），下面的步骤还要用。"
    info "如需手动结束：kill $PF_PID"
  fi
fi

# ---------------------------------------------------------------------------
if want 5; then
  bold "第 5 步：验证 Prefix 的匹配边界（最容易搞错的一点）"
  rule
  if ! curl -s -o /dev/null --max-time 3 "http://localhost:${LOCAL_HTTP_PORT}/" 2>/dev/null; then
    info "本地 ${LOCAL_HTTP_PORT} 没有监听，先起一个 port-forward："
    CSVC=$(find_controller_svc)
    if [ -n "$CSVC" ]; then
      kubectl port-forward -n "${CSVC%%/*}" "svc/${CSVC##*/}" "${LOCAL_HTTP_PORT}:80" >/dev/null 2>&1 &
      sleep 4
      info "已启动 port-forward（$CSVC）"
    else
      warn "找不到控制器 Service，跳过本步骤。"
    fi
  fi
  printf '\n'
  printf '  %-34s %s\n' "请求路径（Host 固定为 note.example.com）" "HTTP 状态"
  printf '  %s\n' "--------------------------------------------------------------"
  for p in "/api" "/api/" "/api/v1" "/api/v1/users" "/apifoo" "/apifoo/x"; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $HOSTNAME_DEMO" "http://localhost:${LOCAL_HTTP_PORT}${p}" 2>/dev/null)
    printf '  %-34s %s\n' "GET $p" "$c"
  done
  printf '\n'
  ok "关键结论：/api、/api/、/api/v1、/api/v1/users 都命中 /api 的规则；"
  info "          /apifoo 和 /apifoo/x 应该落到 web（不被 /api 吃掉）。"
  printf '\n'
  warn "要确认「落到哪个后端」而不是只看状态码，请对比两个应用的访问日志："
  info "  kubectl logs -n $NS -l app=api --tail=10"
  info "  kubectl logs -n $NS -l app=web --tail=10"
  info "日志里出现 GET /apifoo 的应该是 web，不是 api。"
  printf '\n'
  info "Prefix 的分割依据是 / 分隔的路径段，不是字符："
  info "  /api     → [\"api\"]        与 [\"api\"]   匹配"
  info "  /api/v1  → [\"api\",\"v1\"]   第一段是 api  匹配"
  info "  /apifoo  → [\"apifoo\"]     第一段不是 api 不匹配"
fi

# ---------------------------------------------------------------------------
if want 6; then
  bold "第 6 步：配上 TLS（证书集中放在入口，应用侧只写 HTTP）"
  rule
  if ! command -v openssl >/dev/null 2>&1; then
    warn "没有 openssl，跳过本步骤。"
  else
    info "① 生成自签证书（学习中用；生产用 cert-manager 自动申请并轮转）"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /tmp/lab-tls.key -out /tmp/lab-tls.crt \
      -subj "/CN=$HOSTNAME_DEMO" \
      -addext "subjectAltName=DNS:$HOSTNAME_DEMO" >/dev/null 2>&1
    ok "已生成 /tmp/lab-tls.key 与 /tmp/lab-tls.crt"

    printf '\n'
    info "② 存成 kubernetes.io/tls 类型的 Secret（必须含 tls.crt 和 tls.key 两个 key）"
    kubectl create secret tls cloudnote-tls -n "$NS" \
      --key=/tmp/lab-tls.key --cert=/tmp/lab-tls.crt \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl get secret cloudnote-tls -n "$NS"

    printf '\n'
    info "③ 重新 apply Ingress，让它读取这个 Secret"
    kubectl apply -f "$CASE_DIR/40-ingress.yaml" >/dev/null
    kubectl describe ingress cloudnote -n "$NS" 2>/dev/null | grep -A3 -i "TLS" | sed 's/^/    /'

    printf '\n'
    info "④ 用 443 测试（-k 跳过自签证书校验）"
    CSVC=$(find_controller_svc)
    if [ -n "$CSVC" ]; then
      kubectl port-forward -n "${CSVC%%/*}" "svc/${CSVC##*/}" "${LOCAL_HTTPS_PORT}:443" >/dev/null 2>&1 &
      sleep 4
      out=$(curl -sk --max-time 5 --resolve "$HOSTNAME_DEMO:${LOCAL_HTTPS_PORT}:127.0.0.1" \
        "https://$HOSTNAME_DEMO:${LOCAL_HTTPS_PORT}/api" -o /dev/null -w '%{http_code}' 2>/dev/null)
      printf '    HTTPS GET /api  → %s\n' "$out"
      printf '\n'
      info "证书信息："
      curl -skv --max-time 5 --resolve "$HOSTNAME_DEMO:${LOCAL_HTTPS_PORT}:127.0.0.1" \
        "https://$HOSTNAME_DEMO:${LOCAL_HTTPS_PORT}/api" 2>&1 \
        | grep -E "subject:|issuer:|SSL connection" | sed 's/^/    /'
      printf '\n'
      ok "注意：应用 Pod 里没有任何证书，web 和 api 都只是普通的 HTTP nginx，"
      info "      但外部访问已经是 HTTPS —— 这就是「TLS 终止」的价值。"
    else
      info "没找到控制器 Service，跳过 HTTPS 测试。"
    fi
  fi
fi

if [ "$CLEANUP_ONLY" = "0" ]; then
  printf '\n'
  printf '\033[1;33m是否清理本次实验创建的资源？web/api/Ingress/证书都会删除。(y/N) \033[0m'
  read -r answer
  case "$answer" in y|Y) cleanup ;; *) info "保留现场。随时可用 --cleanup 清理。" ;; esac
fi

printf '\n\033[1;32m实验完成。\033[0m对照第 7 章正文【积木 7-9】阅读效果最佳。\n\n'
