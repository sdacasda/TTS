#!/bin/bash
# Azure Speech Portal 一键安装脚本
# 自动克隆仓库、配置环境并启动服务

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# 默认配置
DEFAULT_REPO="https://github.com/sdacasda/TTS.git"
DEFAULT_BRANCH="main"
DEFAULT_INSTALL_DIR="speech-portal"

# 输出函数
print_header() {
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
}

print_info() {
    echo -e "${CYAN}$1${NC}"
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

print_error() {
    echo -e "${RED}$1${NC}"
}

print_step() {
    echo -e "${BLUE}[步骤 $1/$2]${NC} $3"
}

# 读取用户输入
read_input() {
    local prompt="$1"
    local default="$2"
    local required="$3"
    local value
    
    if [ -n "$default" ]; then
        echo -ne "${YELLOW}${prompt} (默认: ${default}): ${NC}"
    else
        echo -ne "${YELLOW}${prompt}: ${NC}"
    fi
    
    read value
    
    if [ -z "$value" ]; then
        if [ -n "$default" ]; then
            echo "$default"
            return
        elif [ "$required" = "true" ]; then
            print_error "错误: 此项为必填项，不能为空！"
            read_input "$prompt" "$default" "$required"
            return
        fi
    fi
    
    echo "$value"
}

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "错误: 未找到 $1 命令"
        print_info "请先安装 $1"
        exit 1
    fi
}

# 验证 Azure 连接
test_azure_connection() {
    local key="$1"
    local region="$2"
    
    print_warning "正在验证 Azure Speech Service 连接..."
    
    local url="https://${region}.tts.speech.microsoft.com/cognitiveservices/voices/list"
    
    if command -v curl &> /dev/null; then
        response=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Ocp-Apim-Subscription-Key: ${key}" \
            -H "User-Agent: speech-portal-installer" \
            "$url" 2>&1)
        
        if [ "$response" = "200" ]; then
            print_success "✓ 连接成功！密钥和区域验证通过。"
            return 0
        else
            print_error "✗ 连接失败: HTTP $response"
            return 1
        fi
    else
        print_warning "⚠ 未找到 curl，跳过连接验证"
        return 0
    fi
}

# 主程序
clear

print_header "Azure Speech Portal 一键安装向导"

# 静默检查依赖
check_command "git" > /dev/null 2>&1 || {
    print_error "错误: 未找到 Git，请先安装 Git"
    exit 1
}

check_command "docker" > /dev/null 2>&1 || {
    print_error "错误: 未找到 Docker，请先安装 Docker"
    exit 1
}

if command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &> /dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    print_error "错误: 未找到 docker-compose 或 docker compose"
    print_info "请先安装 Docker Compose"
    exit 1
fi

echo ""

# 静默克隆代码
install_dir="$DEFAULT_INSTALL_DIR"
if [ -d "$install_dir" ]; then
    rm -rf "$install_dir" 2>/dev/null || true
fi

if ! git clone -b "$DEFAULT_BRANCH" "$DEFAULT_REPO" "$install_dir" -q 2>/dev/null; then
    print_error "✗ 代码克隆失败"
    exit 1
fi

# 进入项目目录
cd "$install_dir/ttl" || {
    print_error "错误: 未找到 ttl 目录"
    exit 1
}

echo ""

# 步骤 1: 配置 Azure Speech Service
print_step 1 2 "配置 Azure Speech Service"
echo ""

print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_info "接下来需要您输入 Azure Speech Service 的密钥和区域"
print_info "如果还没有密钥，请访问 Azure 门户创建:"
print_info "👉 https://portal.azure.com"
print_info "   (Speech Services > 密钥和终结点)"
print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 获取 SPEECH_KEY
print_info "📝 第 1 步: 输入密钥"
speech_key=$(read_input "请输入 Azure Speech Service 密钥" "" "true")

# 获取 SPEECH_REGION
echo ""
echo ""
print_info "📍 第 2 步: 选择服务区域"
print_info "请从以下列表中选择您的 Azure Speech Service 区域："
echo ""
echo "  1) eastasia          - 东亚（香港）"
echo "  2) southeastasia     - 东南亚（新加坡）"
echo "  3) eastus            - 美国东部"
echo "  4) westus            - 美国西部"
echo "  5) westeurope        - 西欧（荷兰）"
echo "  6) northeurope       - 北欧（爱尔兰）"
echo "  7) japaneast         - 日本东部（东京）"
echo "  8) koreacentral      - 韩国中部（首尔）"
echo "  9) australiaeast     - 澳大利亚东部（悉尼）"
echo "  0) 手动输入其他区域"
echo ""

while true; do
    echo -ne "${YELLOW}请选择区域 (1-9 或 0): ${NC}"
    read region_choice
    
    case $region_choice in
        1) speech_region="eastasia"; break;;
        2) speech_region="southeastasia"; break;;
        3) speech_region="eastus"; break;;
        4) speech_region="westus"; break;;
        5) speech_region="westeurope"; break;;
        6) speech_region="northeurope"; break;;
        7) speech_region="japaneast"; break;;
        8) speech_region="koreacentral"; break;;
        9) speech_region="australiaeast"; break;;
        0) 
            speech_region=$(read_input "请输入区域代码" "" "true")
            break;;
        *)
            print_error "无效选择，请输入 0-9"
            continue;;
    esac
done

echo ""
print_success "✓ 已选择区域: $speech_region"
echo ""
print_info "⏳ 正在配置服务..."
echo ""

# 验证连接
print_info "📡 接下来可以验证密钥和区域是否配置正确"
test_connection=$(read_input "是否验证连接? (y/n)" "y" "false")
if [ "$test_connection" = "y" ] || [ "$test_connection" = "Y" ]; then
    if ! test_azure_connection "$speech_key" "$speech_region"; then
        echo ""
        continue_install=$(read_input "连接验证失败，是否继续安装? (y/n)" "n" "false")
        if [ "$continue_install" != "y" ] && [ "$continue_install" != "Y" ]; then
            print_warning "安装已取消。"
            exit 1
        fi
    fi
fi

# 配额限制配置
echo ""
print_info "⚙️  配置使用配额限制"
print_info "配额限制配置 (使用默认值)"
stt_limit="18000"
tts_limit="500000"
pron_limit="18000"
echo ""

configure_limits=$(read_input "是否自定义配额限制? (y/n)" "n" "false")
if [ "$configure_limits" = "y" ] || [ "$configure_limits" = "Y" ]; then
    echo ""
    stt_limit=$(read_input "STT 每月秒数限制" "18000" "false")
    tts_limit=$(read_input "TTS 每月字符数限制" "500000" "false")
    pron_limit=$(read_input "发音评估每月秒数限制" "18000" "false")
fi

# 生成 .env 文件
cat > .env << EOF
# ============================================
# Azure Speech Service 配置
# ============================================
# 生成时间: $(date "+%Y-%m-%d %H:%M:%S")
# 自动安装脚本生成

# Azure Speech Service 订阅密钥
SPEECH_KEY=${speech_key}

# Azure Speech Service 区域
SPEECH_REGION=${speech_region}


# ============================================
# 使用配额限制配置
# ============================================

# STT 每月秒数限制（默认: 18000 = 5小时）
FREE_STT_SECONDS_LIMIT=${stt_limit}

# TTS 每月字符数限制（默认: 500000）
FREE_TTS_CHARS_LIMIT=${tts_limit}

# 发音评估每月秒数限制（默认: 18000 = 5小时）
FREE_PRON_SECONDS_LIMIT=${pron_limit}
EOF

echo ""
print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "✓ 配置完成！密钥和区域已保存到 .env 文件"
print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 步骤 2: 启动服务
print_step 2 2 "启动 Docker 服务"
echo ""

start_service=$(read_input "是否立即启动服务? (y/n)" "y" "false")
if [ "$start_service" = "y" ] || [ "$start_service" = "Y" ]; then
    print_info "正在构建并启动服务..."
    echo ""
    
    if $COMPOSE_CMD up -d --build; then
        echo ""
        print_success "✓ 服务启动成功！"
    else
        echo ""
        print_error "✗ 服务启动失败"
        print_info "请检查 Docker 日志: $COMPOSE_CMD logs"
        exit 1
    fi
else
    print_warning "跳过服务启动。"
    echo ""
    print_info "稍后可以使用以下命令启动服务："
    echo "  cd $(pwd)"
    echo "  $COMPOSE_CMD up -d --build"
fi

# 显示安装摘要
echo ""
print_header "安装完成！"

print_success "🎉 Azure Speech Portal 已成功安装！"
echo ""
print_info "安装信息："
echo "  • 安装目录: $(pwd)"
echo "  • 密钥: ${speech_key:0:8}..."
echo "  • 区域: ${speech_region}"
echo ""

if [ "$start_service" = "y" ] || [ "$start_service" = "Y" ]; then
    print_info "服务访问地址："
    echo "  • 本地: http://localhost:8000"
    
    # 尝试获取服务器 IP
    if command -v hostname &> /dev/null; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [ -n "$server_ip" ]; then
            echo "  • 服务器: http://${server_ip}:8000"
        fi
    fi
    echo ""
    
    print_header "🚀 如何使用"
    print_success "请在浏览器中打开以下地址："
    echo ""
    print_warning "  ➡️  http://localhost:8000"
    echo ""
    if [ -n "$server_ip" ]; then
        print_info "或者使用服务器 IP 访问："
        print_warning "  ➡️  http://${server_ip}:8000"
        echo ""
    fi
    print_success "打开后即可使用语音转文字、文字转语音等功能！"
    echo ""
fi

if [ "$start_service" != "y" ] && [ "$start_service" != "Y" ]; then
    print_header "🚀 如何启动"
    print_info "请执行以下命令启动服务："
    echo "  cd $(pwd)"
    echo "  $COMPOSE_CMD up -d --build"
    echo ""
    print_info "启动后在浏览器中打开："
    print_warning "  ➡️  http://localhost:8000"
    echo ""
fi

print_info "常用命令："
echo "  • 查看日志: $COMPOSE_CMD logs -f"
echo "  • 停止服务: $COMPOSE_CMD down"
echo "  • 重启服务: $COMPOSE_CMD restart"
echo "  • 查看状态: $COMPOSE_CMD ps"
echo ""

print_success "祝您使用愉快！🚀"
echo ""
