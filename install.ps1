#!/usr/bin/env pwsh
# Azure Speech Portal 一键安装脚本
# 自动克隆仓库、配置环境并启动服务

# 设置控制台输出编码为 UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 默认配置
$DEFAULT_REPO = "https://github.com/sdacasda/TTS.git"
$DEFAULT_BRANCH = "main"
$DEFAULT_INSTALL_DIR = "speech-portal"

# 颜色输出函数
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-ColorOutput "============================================" "Cyan"
    Write-ColorOutput "  $Title" "Cyan"
    Write-ColorOutput "============================================" "Cyan"
    Write-Host ""
}

function Write-Step {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Message
    )
    Write-ColorOutput "[步骤 $Current/$Total] $Message" "Blue"
}

function Read-UserInput {
    param(
        [string]$Prompt,
        [string]$DefaultValue = "",
        [bool]$Required = $true,
        [bool]$IsSecret = $false
    )
    
    $promptText = $Prompt
    if ($DefaultValue) {
        $promptText += " (默认: $DefaultValue)"
    }
    $promptText += ": "
    
    Write-Host $promptText -NoNewline -ForegroundColor Yellow
    
    if ($IsSecret) {
        $secureString = Read-Host -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
        $value = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    } else {
        $value = Read-Host
    }
    
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($DefaultValue) {
            return $DefaultValue
        } elseif ($Required) {
            Write-ColorOutput "错误: 此项为必填项，不能为空！" "Red"
            return Read-UserInput -Prompt $Prompt -DefaultValue $DefaultValue -Required $Required -IsSecret $IsSecret
        }
    }
    
    return $value
}

function Test-CommandExists {
    param([string]$Command)
    
    $exists = $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
    return $exists
}

function Test-AzureConnection {
    param(
        [string]$Key,
        [string]$Region
    )
    
    Write-ColorOutput "正在验证 Azure Speech Service 连接..." "Yellow"
    
    $url = "https://$Region.tts.speech.microsoft.com/cognitiveservices/voices/list"
    $headers = @{
        "Ocp-Apim-Subscription-Key" = $Key
        "User-Agent" = "speech-portal-installer"
    }
    
    try {
        $response = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 10 -Method Get
        if ($response.StatusCode -eq 200) {
            Write-ColorOutput "✓ 连接成功！密钥和区域验证通过。" "Green"
            return $true
        }
    } catch {
        Write-ColorOutput "✗ 连接失败: $($_.Exception.Message)" "Red"
        return $false
    }
    
    return $false
}

# 主程序
Clear-Host

Write-Header "Azure Speech Portal 一键安装向导"

# 静默检查依赖
if (-not (Test-CommandExists "git")) {
    Write-ColorOutput "✗ 错误: 未找到 Git，请先安装 Git: https://git-scm.com/" "Red"
    exit 1
}

if (-not (Test-CommandExists "docker")) {
    Write-ColorOutput "✗ 错误: 未找到 Docker，请先安装 Docker: https://www.docker.com/" "Red"
    exit 1
}

# 检查 Docker Compose
$composeCmd = $null
if (Test-CommandExists "docker-compose") {
    $composeCmd = "docker-compose"
} else {
    try {
        docker compose version | Out-Null
        $composeCmd = "docker compose"
    } catch {
        Write-ColorOutput "✗ 错误: 未找到 docker-compose 或 docker compose" "Red"
        Write-ColorOutput "请先安装 Docker Compose" "Yellow"
        exit 1
    }
}

Write-Host ""

# 静默克隆代码
$installDir = $DEFAULT_INSTALL_DIR
if (Test-Path $installDir) {
    Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}

try {
    git clone -b $DEFAULT_BRANCH $DEFAULT_REPO $installDir -q 2>&1 | Out-Null
} catch {
    Write-ColorOutput "✗ 代码克隆失败: $($_.Exception.Message)" "Red"
    exit 1
}

# 进入项目目录
$projectPath = Join-Path $installDir "ttl"
if (-not (Test-Path $projectPath)) {
    Write-ColorOutput "✗ 错误: 未找到 ttl 目录" "Red"
    exit 1
}

Set-Location $projectPath
Write-Host ""

# 步骤 1: 配置 Azure Speech Service
Write-Step -Current 1 -Total 2 -Message "配置 Azure Speech Service"
Write-Host ""

Write-ColorOutput "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "Yellow"
Write-ColorOutput "接下来需要您输入 Azure Speech Service 的密钥和区域" "Cyan"
Write-ColorOutput "如果还没有密钥，请访问 Azure 门户创建:" "Cyan"
Write-ColorOutput "👉 https://portal.azure.com" "Cyan"
Write-ColorOutput "   (Speech Services > 密钥和终结点)" "Cyan"
Write-ColorOutput "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "Yellow"
Write-Host ""

# 获取 SPEECH_KEY
Write-ColorOutput "📝 第 1 步: 输入密钥" "Cyan"
$speechKey = Read-UserInput -Prompt "请输入 Azure Speech Service 密钥" -Required $true

# 获取 SPEECH_REGION
Write-Host ""
Write-Host ""
Write-ColorOutput "📍 第 2 步: 选择服务区域" "Cyan"
Write-ColorOutput "请从以下列表中选择您的 Azure Speech Service 区域：" "Cyan"
Write-Host ""
Write-Host "  1) eastasia          - 东亚（香港）"
Write-Host "  2) southeastasia     - 东南亚（新加坡）"
Write-Host "  3) eastus            - 美国东部"
Write-Host "  4) westus            - 美国西部"
Write-Host "  5) westeurope        - 西欧（荷兰）"
Write-Host "  6) northeurope       - 北欧（爱尔兰）"
Write-Host "  7) japaneast         - 日本东部（东京）"
Write-Host "  8) koreacentral      - 韩国中部（首尔）"
Write-Host "  9) australiaeast     - 澳大利亚东部（悉尼）"
Write-Host "  0) 手动输入其他区域"
Write-Host ""

$speechRegion = $null
while ($null -eq $speechRegion) {
    Write-Host "请选择区域 (1-9 或 0): " -NoNewline -ForegroundColor Yellow
    $regionChoice = Read-Host
    
    switch ($regionChoice) {
        "1" { $speechRegion = "eastasia"; break }
        "2" { $speechRegion = "southeastasia"; break }
        "3" { $speechRegion = "eastus"; break }
        "4" { $speechRegion = "westus"; break }
        "5" { $speechRegion = "westeurope"; break }
        "6" { $speechRegion = "northeurope"; break }
        "7" { $speechRegion = "japaneast"; break }
        "8" { $speechRegion = "koreacentral"; break }
        "9" { $speechRegion = "australiaeast"; break }
        "0" { 
            $speechRegion = Read-UserInput -Prompt "请输入区域代码" -Required $true
            break
        }
        default {
            Write-ColorOutput "无效选择，请输入 0-9" "Red"
            continue
        }
    }
}

# 静默生成配置文件
$sttLimit = "18000"
$ttsLimit = "500000"
$pronLimit = "18000"

# 生成 .env 文件内容
$envContent = @"
# ============================================
# Azure Speech Service 配置
# ============================================
# 生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# 自动安装脚本生成

# Azure Speech Service 订阅密钥
SPEECH_KEY=$speechKey

# Azure Speech Service 区域
SPEECH_REGION=$speechRegion


# ============================================
# 使用配额限制配置
# ============================================

# STT 每月秒数限制（默认: 18000 = 5小时）
FREE_STT_SECONDS_LIMIT=$sttLimit

# TTS 每月字符数限制（默认: 500000）
FREE_TTS_CHARS_LIMIT=$ttsLimit

# 发音评估每月秒数限制（默认: 18000 = 5小时）
FREE_PRON_SECONDS_LIMIT=$pronLimit
"@

# 保存文件
try {
    $envContent | Out-File -FilePath ".env" -Encoding UTF8 -NoNewline
    Write-Host ""
} catch {
    Write-ColorOutput "✗ 保存配置文件失败: $($_.Exception.Message)" "Red"
    exit 1
}

Write-Host ""

# 步骤 2: 启动服务
Write-Step -Current 2 -Total 2 -Message "启动 Docker 服务"
Write-Host ""

Write-ColorOutput "正在构建并启动服务..." "Cyan"
Write-Host ""
    
    try {
        if ($composeCmd -eq "docker-compose") {
            docker-compose up -d --build
        } else {
            docker compose up -d --build
        }
        
        Write-Host ""
        # 等待服务启动
        Write-ColorOutput "等待服务启动..." "Cyan"
        Start-Sleep -Seconds 5
        
        # 检查容器状态
        $psOutput = if ($composeCmd -eq "docker-compose") {
            docker-compose ps
        } else {
            docker compose ps
        }
        
        if ($psOutput -match "speech-portal") {
            Write-ColorOutput "✓ 容器已启动" "Green"
            Write-Host ""
            
            # HTTP 健康检查
            Write-ColorOutput "正在检查服务健康状态..." "Cyan"
            $maxAttempts = 10
            $serviceOk = $false
            
            for ($i = 0; $i -lt $maxAttempts; $i++) {
                try {
                    $response = Invoke-WebRequest -Uri "http://localhost:8000/api/health" -TimeoutSec 1 -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        $serviceOk = $true
                        break
                    }
                } catch {
                    Start-Sleep -Seconds 1
                }
            }
            
            Write-Host ""
            if ($serviceOk) {
                Write-ColorOutput "✓ 服务健康检查通过！" "Green"
            } else {
                Write-ColorOutput "✗ 服务无法访问 (ERR_EMPTY_RESPONSE)" "Red"
                Write-Host ""
                Write-ColorOutput "容器已启动但服务未响应，可能原因：" "Yellow"
                Write-ColorOutput "  • 应用程序启动失败" "White"
                Write-ColorOutput "  • 配置错误（密钥或区域）" "White"
                Write-ColorOutput "  • 端口被占用" "White"
                Write-Host ""
                Write-ColorOutput "请查看容器日志排查问题：" "Cyan"
                Write-ColorOutput "  $composeCmd logs" "White"
                Write-Host ""
                Write-ColorOutput "查看最近的错误日志：" "Cyan"
                Write-ColorOutput "  $composeCmd logs --tail=50 speech-portal" "White"
                Write-Host ""
                Write-Host "按回车键查看实时日志..." -NoNewline
                Read-Host
                if ($composeCmd -eq "docker-compose") {
                    docker-compose logs -f
                } else {
                    docker compose logs -f
                }
            }
            Write-Host ""
            Write-ColorOutput "当前运行的容器：" "Cyan"
            Write-Host $psOutput
        } else {
            Write-ColorOutput "⚠ 容器未找到，请检查状态" "Yellow"
            Write-Host ""
            Write-ColorOutput "请检查日志：" "Cyan"
            Write-ColorOutput "  $composeCmd logs" "White"
        }
    } catch {
        Write-Host ""
        Write-ColorOutput "✗ 服务启动失败: $($_.Exception.Message)" "Red"
        Write-Host ""
        Write-ColorOutput "请尝试以下排查步骤：" "Cyan"
        Write-ColorOutput "  1. 检查 Docker 是否正在运行: docker ps" "White"
        Write-ColorOutput "  2. 查看详细日志: cd $((Get-Location).Path); $composeCmd logs" "White"
        Write-ColorOutput "  3. 检查配置文件: cat .env" "White"
        Write-ColorOutput "  4. 手动启动: cd $((Get-Location).Path); $composeCmd up --build" "White"
        exit 1
    }
}

# 显示安装摘要
Write-Host ""
Write-Header "安装完成！"

Write-ColorOutput "🎉 Azure Speech Portal 已成功安装！" "Green"
Write-Host ""
Write-ColorOutput "安装信息：" "Cyan"
Write-ColorOutput "  • 安装目录: $((Get-Location).Path)" "White"
Write-ColorOutput "  • 密钥: $($speechKey.Substring(0, 8))..." "White"
Write-ColorOutput "  • 区域: $speechRegion" "White"
Write-Host ""

if ($startService -eq "y" -or $startService -eq "Y") {
    Write-ColorOutput "服务访问地址：" "Cyan"
    Write-ColorOutput "  • 本地: http://localhost:8000" "White"
    
    # 尝试获取服务器 IP
    try {
        $serverIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" -and $_.IPAddress -notmatch "^169" } | Select-Object -First 1).IPAddress
        if ($serverIp) {
            Write-ColorOutput "  • 服务器: http://${serverIp}:8000" "White"
        }
    } catch {
        # 忽略错误
    }
    Write-Host ""
    
    Write-Header "🚀 如何使用"
    Write-ColorOutput "请在浏览器中打开以下地址：" "Green"
    Write-Host ""
    Write-ColorOutput "  ➡️  http://localhost:8000" "Yellow"
    Write-Host ""
    if ($serverIp) {
        Write-ColorOutput "或者使用服务器 IP 访问：" "Cyan"
        Write-ColorOutput "  ➡️  http://${serverIp}:8000" "Yellow"
        Write-Host ""
    }
    Write-ColorOutput "打开后即可使用语音转文字、文字转语音等功能！" "Green"
    Write-Host ""
}

Write-ColorOutput "常用命令：" "Cyan"
Write-ColorOutput "  • 查看日志: $composeCmd logs -f" "White"
Write-ColorOutput "  • 停止服务: $composeCmd down" "White"
Write-ColorOutput "  • 重启服务: $composeCmd restart" "White"
Write-ColorOutput "  • 查看状态: $composeCmd ps" "White"
Write-Host ""

Write-ColorOutput "祝您使用愉快！🚀" "Green"
Write-Host ""
