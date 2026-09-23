#!/usr/bin/env bash
# ============================================================================
# 第 8 章动手实验：一次看清配置注入的三种行为
#
# 核心实验：同一个 Pod 里同时用三种方式读同一个 ConfigMap，
#           改一次 ConfigMap，等 90 秒，看哪一路变了。
#             ① 环境变量     → 不变
#             ② 目录挂载     → 变了
#             ③ subPath 挂载 → 不变
#
# 另外还会验证：Secret 到底有没有「加密」、目录覆盖的坑、optional 的作用。
#
# 全程只操作 cloudnote 命名空间里本章创建的对象，结束自动清理。
#
# 用法：
#   bash cases/cloudnote/tools/config-lab.sh            # 跑全部
#   bash cases/cloudnote/tools/config-lab.sh 4 5        # 只跑指定步骤
#   bash cases/cloudnote/tools/config-lab.sh --cleanup  # 只做清理
# ============================================================================
set -uo pipefail

NS="cloudnote"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
SYNC_WAIT=95   # kubelet 同步周期默认 1 分钟，留足余量

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
cmd()  { printf '\033[2m  $ %s\033[0m\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
ok()   { printf '\033[1;32m  %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  %s\033[0m\n' "$1"; }

read_three() {
  kubectl exec config-demo -n "$NS" -- sh -c '
    echo "① 环境变量      LOG_LEVEL = $LOG_LEVEL"
    echo "② 目录挂载      = $(cat /etc/app/log.level 2>/dev/null)"
    echo "③ subPath 挂载  = $(cat /etc/app-single/log.level 2>/dev/null)"
  ' 2>/dev/null
}

cleanup() {
  bold "清理实验资源"
  kubectl delete pod config-demo opt-cm nginx-broken -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  kubectl delete configmap api-config -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  kubectl delete secret api-secret -n "$NS" --ignore-not-found=true >/dev/null 2>&1
  ok "已清理 config-demo / opt-cm / nginx-broken / api-config / api-secret。"
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

printf '\n\033[1;33m本实验会在 %s 命名空间创建 ConfigMap/Secret 与几个演示 Pod，结束自动清理。\033[0m\n' "$NS"
printf '继续？(y/N) '
read -r answer
case "$answer" in y|Y) ;; *) printf '已取消。\n'; exit 0 ;; esac

want() { for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# ---------------------------------------------------------------------------
if want 1; then
  bold "第 1 步：创建 ConfigMap 与 Secret"
  rule
  kubectl apply -f "$CASE_DIR/00-namespace.yaml" >/dev/null
  kubectl apply -f "$CASE_DIR/10-config.yaml"
  printf '\n'
  kubectl get configmap,secret -n "$NS"
  printf '\n'
  info "ConfigMap 的 data："
  kubectl get configmap api-config -n "$NS" -o jsonpath='{.data}' | sed 's/^/    /'
  printf '\n\n'
  info "注意 Secret 存的不是明文 —— 但它是 base64，不是加密。下一步就验证。"
fi

# ---------------------------------------------------------------------------
if want 2; then
  bold "第 2 步：验证「Secret 默认不是加密」"
  rule
  info "① kubectl describe：只显示字节数，不显示值"
  kubectl describe secret api-secret -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "② kubectl get -o yaml：看到 base64 编码后的一串字符"
  kubectl get secret api-secret -n "$NS" -o jsonpath='{.data.DB_PASSWORD}' | sed 's/^/    /'
  printf '\n\n'
  info "③ 一行命令解出明文："
  PW=$(kubectl get secret api-secret -n "$NS" -o jsonpath='{.data.DB_PASSWORD}' | base64 -d 2>/dev/null)
  printf '    base64 -d  →  %s\n' "$PW"
  printf '\n'
  ok "看到了吗？这就是「Secret 默认不是加密」的实证。"
  warn "所以：Secrets 的 YAML 绝对不要提交进 Git。"
  info "让密码真正安全的四层做法：不进 Git（Sealed Secrets/SOPS/ESO）→ etcd 静态加密"
  info "  → RBAC 最小权限 → 外部密钥管理（Vault/云 KMS）。详见第 8 章积木 8-2。"
  printf '\n'
  info "另外注意：stringData 是「只写字段」，读出来只会看到 data："
  kubectl get secret api-secret -n "$NS" -o jsonpath='{.stringData}' | sed 's/^/    stringData = /'
  printf '（空）（写入时已被 API Server 转成 base64 存进 data）\n'
fi

# ---------------------------------------------------------------------------
if want 3; then
  bold "第 3 步：创建三种注入方式并存的 Pod"
  rule
  kubectl get configmap api-config -n "$NS" >/dev/null 2>&1 || kubectl apply -f "$CASE_DIR/10-config.yaml" >/dev/null
  kubectl apply -f "$CASE_DIR/18-config-demo.yaml" >/dev/null
  kubectl wait --for=condition=Ready pod/config-demo -n "$NS" --timeout=90s >/dev/null 2>&1
  printf '\n'
  kubectl get pod config-demo -n "$NS"
  printf '\n'
  info "这个 Pod 里同时有："
  info "  ① 环境变量      configMapKeyRef  → \$LOG_LEVEL"
  info "  ② 目录卷挂载    /etc/app/log.level"
  info "  ③ subPath 单文件 /etc/app-single/log.level"
  printf '\n'
  info "初始三路的值："
  read_three | sed 's/^/    /'
  printf '\n'
  info "看 kubelet 是怎么组织目录挂载的（注意 ..data 软链接）："
  kubectl exec config-demo -n "$NS" -- ls -la /etc/app/ 2>/dev/null | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
if want 4; then
  bold "第 4 步：改 ConfigMap，等待 kubelet 同步（本章最关键的一次观察）"
  rule
  info "把 log.level 从当前值改成 error"
  kubectl patch configmap api-config -n "$NS" --type merge -p '{"data":{"log.level":"error"}}' >/dev/null
  printf '    %s  已修改，等待 %s 秒（kubelet 同步周期默认 1 分钟）...\n' "$(date +%H:%M:%S)" "$SYNC_WAIT"
  sleep "$SYNC_WAIT"
  printf '\n'
  info "现在三路的值："
  read_three | sed 's/^/    /'
  printf '\n'
  ok "结论对照："
  printf '    %-20s %-16s %s\n' "注入方式" "会不会更新" "为什么"
  printf '    %s\n' "--------------------------------------------------------------"
  printf '    %-20s %-16s %s\n' "① 环境变量" "不会" "环境变量是容器创建时注入进程的"
  printf '    %-20s %-16s %s\n' "② 目录挂载" "会（约1分钟）" "kubelet 持续同步并原子替换软链接"
  printf '    %-20s %-16s %s\n' "③ subPath 挂载" "永不更新" "bind mount 到具体文件，官方设计如此"
  printf '\n'
  warn "但这三行只说明「文件变了」—— 配置有没有「生效」，取决于应用会不会重载它。"
fi

# ---------------------------------------------------------------------------
if want 5; then
  bold "第 5 步：用滚动重启让配置真正生效"
  rule
  info "重建前："
  read_three | sed 's/^/    /'
  printf '\n'
  info "① 对 Deployment 用 rollout restart（它是给 Pod 模板加一个时间戳注解，触发标准滚动更新）"
  info "   kubectl rollout restart deployment/api -n $NS"
  info "   （本实验没有常驻的 api Deployment，跳过；第 5 章已演示过）"
  printf '\n'
  info "② 对 demo 这个裸 Pod，直接删了重建："
  kubectl delete pod config-demo -n "$NS" --wait=false >/dev/null 2>&1
  sleep 5
  kubectl apply -f "$CASE_DIR/18-config-demo.yaml" >/dev/null
  kubectl wait --for=condition=Ready pod/config-demo -n "$NS" --timeout=90s >/dev/null 2>&1
  printf '\n'
  info "重建后："
  read_three | sed 's/^/    /'
  printf '\n'
  ok "环境变量现在才变成新值 —— 这就是「改了配置但不生效」的根源。"
  printf '\n'
  info "根治「改配置自动触发发布」的四种方案："
  info "  ① kubectl rollout restart（最简单）"
  info "  ② ConfigMap 名字带版本号 api-config-v3 + immutable: true（最稳）"
  info "  ③ 把 ConfigMap 内容的 checksum 写进 Pod 模板 annotation（Helm 标准做法）"
  info "  ④ 部署 stakater/Reloader 这类工具自动触发"
fi

# ---------------------------------------------------------------------------
if want 6; then
  bold "第 6 步：验证「目录挂载是覆盖，不是合并」"
  rule
  warn "这一步故意把整个 /etc/nginx 挂上一个只含几个文件的 ConfigMap，制造故障。"
  kubectl delete pod nginx-broken -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  sleep 3
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nginx-broken
  namespace: cloudnote
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      volumeMounts:
        - name: cfg
          mountPath: /etc/nginx
  volumes:
    - name: cfg
      configMap:
        name: api-config
EOF
  sleep 12
  printf '\n'
  kubectl get pod nginx-broken -n "$NS" | sed 's/^/    /'
  printf '\n'
  info "容器日志："
  kubectl logs nginx-broken -n "$NS" 2>&1 | head -6 | sed 's/^/    /'
  printf '\n'
  ok "nginx 因为找不到 mime.types 起不来 —— 因为挂载把镜像里 /etc/nginx 下的"
  info "其他所有文件都「遮住」了（不是删除，是被覆盖）。"
  printf '\n'
  info "正确做法：挂到专用子目录（如 /etc/nginx/conf.d），或用 items 精确指定要挂的 key。"
  kubectl delete pod nginx-broken -n "$NS" --wait=false >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
if want 7; then
  bold "第 7 步：验证 optional 的作用（配置缺失时是否阻塞启动）"
  rule
  kubectl delete pod opt-cm -n "$NS" --ignore-not-found=true --wait=false >/dev/null 2>&1
  sleep 3
  printf '\n'
  info "① 引用一个不存在的 ConfigMap，且不加 optional："
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: opt-cm
  namespace: cloudnote
spec:
  containers:
    - name: demo
      image: busybox:1.36
      command: ["sh","-c","sleep 3600"]
      envFrom:
        - configMapRef:
            name: not-exist-config
EOF
  sleep 12
  kubectl get pod opt-cm -n "$NS" | sed 's/^/    /'
  printf '    （STATUS 应该是 CreateContainerConfigError，Pod 起不来）\n'
  printf '\n'
  info "② 加上 optional: true 再试："
  kubectl delete pod opt-cm -n "$NS" --wait=false >/dev/null 2>&1
  sleep 4
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: opt-cm
  namespace: cloudnote
spec:
  containers:
    - name: demo
      image: busybox:1.36
      command: ["sh","-c","echo 'Pod 正常启动了（配置缺失但不阻塞）'; sleep 3600"]
      envFrom:
        - configMapRef:
            name: not-exist-config
            optional: true
EOF
  kubectl wait --for=condition=Ready pod/opt-cm -n "$NS" --timeout=90s >/dev/null 2>&1
  kubectl get pod opt-cm -n "$NS" | sed 's/^/    /'
  kubectl logs opt-cm -n "$NS" 2>/dev/null | sed 's/^/    /'
  printf '\n'
  ok "optional: true 让「应用先起来、配置后补上」成为可能 —— 部署解耦的实用开关。"
fi

printf '\n'
printf '\033[1;33m是否清理本次实验创建的资源？(y/N) \033[0m'
read -r answer
case "$answer" in y|Y) cleanup ;; *) info "保留现场。随时可用 --cleanup 清理。" ;; esac

printf '\n\033[1;32m实验完成。\033[0m对照第 8 章正文【积木 8-8】阅读效果最佳。\n\n'
