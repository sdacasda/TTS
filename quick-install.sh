#!/bin/bash
# Azure Speech Portal 快速安装脚本（无交互版本）
# 自动使用默认配置完成安装

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 默认配置（无需修改）
REPO="https://github.com/sdacasda/TTS.git"
BRANCH="main"
INSTALL_DIR="speech-portal"

echo -e "${CYAN}==============================================
  Azure Speech Portal 快速安装
==============================================${NC}\n"

# 必需参数检查
if [ -z "$SPEECH_KEY" ] || [ -z "$SPEECH_REGION" ]; then
    echo -e "${RED}错误: 请先设置环境变量！${NC}\n"
    echo "使用方法："
    echo -e "${YELLOW}export SPEECH_KEY='你的Azure密钥'${NC}"
    echo -e "${YELLOW}export SPEECH_REGION='你的区域'${NC}"
    echo -e "${YELLOW}curl -fsSL https://raw.githubusercontent.com/sdacasda/TTS/main/ttl/quick-install.sh | bash${NC}\n"
    echo "示例："
    echo -e "${CYAN}export SPEECH_KEY='a1b2c3d4...'${NC}"
    echo -e "${CYAN}export SPEECH_REGION='eastasia'${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 环境变量已设置${NC}"
echo "  密钥: ${SPEECH_KEY:0:8}..."
echo "  区域: $SPEECH_REGION"
echo ""

# 检查依赖
for cmd in git docker; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${RED}✗ 未找到 $cmd${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ $cmd 已安装${NC}"
done

# 检查 Docker Compose
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    echo -e "${RED}✗ 未找到 docker-compose${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Docker Compose 已安装${NC}\n"

# 删除旧安装（如果存在）
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}⚠ 删除旧安装目录...${NC}"
    rm -rf "$INSTALL_DIR"
fi

# 克隆代码
echo -e "${CYAN}[1/3] 克隆代码...${NC}"
git clone -b "$BRANCH" "$REPO" "$INSTALL_DIR" --depth 1 -q
echo -e "${GREEN}✓ 代码克隆完成${NC}\n"

# 生成配置
cd "$INSTALL_DIR/ttl"
echo -e "${CYAN}[2/3] 生成配置文件...${NC}"

cat > .env << EOF
# Azure Speech Service 配置
# 生成时间: $(date "+%Y-%m-%d %H:%M:%S")

SPEECH_KEY=$SPEECH_KEY
SPEECH_REGION=$SPEECH_REGION

# 配额限制
FREE_STT_SECONDS_LIMIT=18000
FREE_TTS_CHARS_LIMIT=500000
FREE_PRON_SECONDS_LIMIT=18000
EOF

# 如果有 OPENAI_TTS_API_KEY，也添加
if [ -n "$OPENAI_TTS_API_KEY" ]; then
    echo "OPENAI_TTS_API_KEY=$OPENAI_TTS_API_KEY" >> .env
fi

echo -e "${GREEN}✓ 配置文件已生成${NC}\n"

# 启动服务
echo -e "${CYAN}[3/3] 启动服务...${NC}"
$COMPOSE_CMD up -d --build

if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🎉 安装成功！
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    echo -e "${CYAN}访问地址：${NC}"
    echo "  • 本地: http://localhost:8000"
    
    # 尝试获取服务器 IP
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    if [ -n "$SERVER_IP" ]; then
        echo "  • 服务器: http://${SERVER_IP}:8000"
    fi
    
    echo -e "\n${CYAN}常用命令：${NC}"
    echo "  • 查看日志: cd $(pwd) && $COMPOSE_CMD logs -f"
    echo "  • 停止服务: cd $(pwd) && $COMPOSE_CMD down"
    echo "  • 重启服务: cd $(pwd) && $COMPOSE_CMD restart"
    echo ""
else
    echo -e "\n${RED}✗ 服务启动失败${NC}"
    echo "请查看日志: cd $(pwd) && $COMPOSE_CMD logs"
    exit 1
fi
