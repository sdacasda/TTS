#!/bin/bash
# Azure Speech Service 交互式配置脚本
# 用于引导用户配置 .env 文件

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

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

# 验证 Azure 连接
test_azure_connection() {
    local key="$1"
    local region="$2"
    
    print_warning "正在验证 Azure Speech Service 连接..."
    
    local url="https://${region}.tts.speech.microsoft.com/cognitiveservices/voices/list"
    
    if command -v curl &> /dev/null; then
        response=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Ocp-Apim-Subscription-Key: ${key}" \
            -H "User-Agent: speech-portal-setup" \
            "$url" 2>&1)
        
        if [ "$response" = "200" ]; then
            print_success "✓ 连接成功！密钥和区域验证通过。"
            return 0
        else
            print_error "✗ 连接失败: HTTP $response"
            return 1
        fi
    elif command -v wget &> /dev/null; then
        if wget --spider --quiet \
            --header="Ocp-Apim-Subscription-Key: ${key}" \
            --header="User-Agent: speech-portal-setup" \
            "$url" 2>&1; then
            print_success "✓ 连接成功！密钥和区域验证通过。"
            return 0
        else
            print_error "✗ 连接失败"
            return 1
        fi
    else
        print_warning "⚠ 未找到 curl 或 wget，跳过连接验证"
        return 0
    fi
}

# 主程序
clear

print_header "Azure Speech Service 配置向导"

print_success "欢迎使用 Azure Speech Service 门户配置向导！"
echo ""
echo "本向导将帮助您配置 Azure Speech Service 所需的环境变量。"
echo ""

# 检查是否已存在 .env 文件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="${SCRIPT_DIR}/.env"

if [ -f "$ENV_PATH" ]; then
    print_warning "⚠ 警告: .env 文件已存在！"
    echo ""
    overwrite=$(read_input "是否要覆盖现有配置? (y/n)" "n" "false")
    if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
        print_warning "配置已取消。"
        exit 0
    fi
    echo ""
fi

print_header "步骤 1: Azure Speech Service 配置"

print_info "请访问 Azure Portal 获取以下信息："
echo "1. 登录: https://portal.azure.com"
echo "2. 搜索并创建 'Speech Services' 资源"
echo "3. 在'密钥和终结点'页面获取密钥和区域"
echo ""

# 获取 SPEECH_KEY
speech_key=$(read_input "请输入 Azure Speech Service 密钥 (KEY1 或 KEY2)" "" "true")

# 获取 SPEECH_REGION
echo ""
print_info "请选择 Azure Speech Service 区域："
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

# 验证连接
echo ""
test_connection=$(read_input "是否验证连接? (y/n)" "y" "false")
if [ "$test_connection" = "y" ] || [ "$test_connection" = "Y" ]; then
    if ! test_azure_connection "$speech_key" "$speech_region"; then
        echo ""
        continue_save=$(read_input "连接验证失败，是否仍要继续保存配置? (y/n)" "n" "false")
        if [ "$continue_save" != "y" ] && [ "$continue_save" != "Y" ]; then
            print_warning "配置已取消。"
            exit 1
        fi
    fi
fi

echo ""
print_header "步骤 2: 配额限制配置 (可选)"

print_info "Azure Speech Free (F0) 层每月免费额度："
echo "  - STT (语音转文本): 5小时 = 18000秒"
echo "  - TTS (文本转语音): 500,000字符"
echo "  - 发音评估: 5小时 = 18000秒"
echo ""

use_limits=$(read_input "是否配置配额限制? (y/n)" "n" "false")

if [ "$use_limits" = "y" ] || [ "$use_limits" = "Y" ]; then
    echo ""
    stt_limit=$(read_input "STT 每月秒数限制" "18000" "false")
    tts_limit=$(read_input "TTS 每月字符数限制" "500000" "false")
    pron_limit=$(read_input "发音评估每月秒数限制" "18000" "false")
else
    stt_limit="18000"
    tts_limit="500000"
    pron_limit="18000"
fi

# 生成 .env 文件内容
echo ""
print_header "生成配置文件"

cat > "$ENV_PATH" << EOF
# ============================================
# Azure Speech Service 配置
# ============================================
# 生成时间: $(date "+%Y-%m-%d %H:%M:%S")

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

if [ $? -eq 0 ]; then
    print_success "✓ 配置文件已成功保存到: $ENV_PATH"
else
    print_error "✗ 保存配置文件失败"
    exit 1
fi

# 显示摘要
echo ""
print_header "配置摘要"

echo "密钥: ${speech_key:0:8}..."
echo "区域: ${speech_region}"
echo "STT 限制: ${stt_limit} 秒"
echo "TTS 限制: ${tts_limit} 字符"
echo "发音评估限制: ${pron_limit} 秒"

echo ""
print_header "下一步操作"

print_success "配置已完成！您现在可以："
echo ""
print_info "1. 启动服务:"
echo "   docker compose up -d --build"
echo ""
print_info "2. 访问服务:"
echo "   http://localhost:8000"
echo ""
print_info "3. 查看日志:"
echo "   docker compose logs -f"
echo ""

print_success "祝您使用愉快！🎉"
echo ""
