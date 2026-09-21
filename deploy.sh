#!/bin/bash
#===========================================================
# OpenAppSec WAF 快速部署脚本
# 适用于：Linux (Rocky/CentOS/Ubuntu)
# 前置条件：已安装 podman + podman-compose
# 使用方式：bash deploy.sh
#===========================================================

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=${DEPLOY_DIR:-/opt/waf/open-appsec}
BACKEND_PORT=${BACKEND_PORT:-3002}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_step() { echo -e "${GREEN}[STEP]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
echo_err()   { echo -e "${RED}[ERR]${NC} $1"; }

#-----------------------------------------------
# 1. 前置检查
#-----------------------------------------------
echo_step "检查 podman..."
if ! command -v podman &>/dev/null; then
    echo_err "podman 未安装，请先安装 podman"
    exit 1
fi
echo_ok "podman $(podman --version)"

echo_step "检查 podman-compose..."
if ! command -v podman-compose &>/dev/null; then
    echo_err "podman-compose 未安装"
    exit 1
fi
echo_ok "podman-compose 已就绪"

#-----------------------------------------------
# 2. 初始化共享内存目录
#-----------------------------------------------
echo_step "初始化共享内存目录 /mnt/check-point-shm..."
mkdir -p /mnt/check-point-shm
chmod 777 /mnt/check-point-shm
echo_ok "共享内存目录就绪"

#-----------------------------------------------
# 3. 加载 Docker 镜像
#-----------------------------------------------
IMAGE_TAR="${SCRIPT_DIR}/images/agent-unified.1.1.36.tar"
if [[ -f "$IMAGE_TAR" ]]; then
    echo_step "加载镜像 agent-unified:1.1.36 ($(du -h "$IMAGE_TAR" | cut -f1))..."
    podman load -i "$IMAGE_TAR" | tail -1
    echo_ok "镜像加载完成"
else
    echo_warn "镜像文件未找到: $IMAGE_TAR，跳过（需自行拉取或导入）"
fi

#-----------------------------------------------
# 4. 部署目录准备
#-----------------------------------------------
echo_step "准备部署目录..."
if [[ -d "$DEPLOY_DIR" ]]; then
    echo_warn "部署目录已存在: $DEPLOY_DIR"
    read -p "是否覆盖现有部署？(y/N): " confirm
    [[ "$confirm" != "y" ]] && { echo "退出部署"; exit 0; }
    $SUDO podman-compose -f "$DEPLOY_DIR/docker-compose.yaml" down 2>/dev/null || true
fi

mkdir -p "$DEPLOY_DIR"
cp -r "${SCRIPT_DIR}/config/"* "$DEPLOY_DIR/"
mkdir -p "$DEPLOY_DIR/appsec-config" "$DEPLOY_DIR/appsec-data"         "$DEPLOY_DIR/appsec-logs" "$DEPLOY_DIR/appsec-smartsync-storage"
mkdir -p /mnt/check-point-shm

echo_ok "部署目录准备完成: $DEPLOY_DIR"

#-----------------------------------------------
# 5. 确认后端服务
#-----------------------------------------------
echo_step "检查后端服务 (端口 ${BACKEND_PORT})..."
if ss -tlnp | grep -q ":${BACKEND_PORT}"; then
    echo_ok "后端服务已在端口 ${BACKEND_PORT} 运行"
else
    echo_warn "后端服务未在端口 ${BACKEND_PORT} 监听，请确保后端已启动"
fi

#-----------------------------------------------
# 6. 启动 WAF
#-----------------------------------------------
echo_step "启动 OpenAppSec WAF..."
cd "$DEPLOY_DIR"
podman-compose up -d

echo_ok "容器启动命令已执行"
echo "等待 25 秒让各进程就绪..."
sleep 25

#-----------------------------------------------
# 7. 验证
#-----------------------------------------------
echo_step "验证端口 80..."
if ss -tlnp | grep -q ':80'; then
    echo_ok "端口 80 已监听 (nginx 或 WAF)"
else
    echo_err "端口 80 未监听，部署可能未成功"
fi

echo_step "重载 nginx 配置..."
podman exec appsec-agent nginx -t && podman exec appsec-agent nginx -s reload 2>/dev/null || echo_warn "nginx reload 跳过（无重载权限或无需重载）"

echo_step "测试正常请求..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
    echo_ok "后端代理正常，HTTP $HTTP_CODE"
else
    echo_warn "端口 80 返回 HTTP $HTTP_CODE（可能后端未就绪或 WAF 拦截）"
fi

echo_step "测试 WAF 拦截..."
BLOCK_CODE=$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:80/?id=1%20OR%201%3D1' 2>/dev/null || echo "000")
if [[ "$BLOCK_CODE" == "403" ]]; then
    echo_ok "WAF 拦截正常，SQL注入返回 HTTP $BLOCK_CODE"
else
    echo_warn "WAF 未拦截，SQL注入返回 HTTP $BLOCK_CODE"
fi

echo ""
echo_ok "=============================================="
echo_ok "  OpenAppSec WAF 部署完成！"
echo_ok "=============================================="
echo "  部署目录: $DEPLOY_DIR"
echo "  WAF 端口: 80"
echo "  后端端口: ${BACKEND_PORT}"
echo "  查看日志: cd $DEPLOY_DIR && podman-compose logs -f"
echo "  停止服务: cd $DEPLOY_DIR && podman-compose down"
echo_ok "=============================================="
