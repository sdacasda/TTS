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

Write-ColorOutput "欢迎使用 Azure Speech Portal 一键安装脚本！" "Green"
Write-Host ""
Write-ColorOutput "本脚本将帮助您：" "White"
Write-ColorOutput "  1. 克隆项目代码" "White"
Write-ColorOutput "  2. 配置 Azure Speech Service" "White"
Write-ColorOutput "  3. 启动 Docker 服务" "White"
Write-Host ""

# 步骤 1: 检查依赖
Write-Step -Current 1 -Total 5 -Message "检查系统依赖"
Write-Host ""

# 检查 Git
if (Test-CommandExists "git") {
    Write-ColorOutput "✓ Git 已安装" "Green"
} else {
    Write-ColorOutput "✗ 错误: 未找到 Git" "Red"
    Write-ColorOutput "请先安装 Git: https://git-scm.com/" "Yellow"
    exit 1
}

# 检查 Docker
if (Test-CommandExists "docker") {
    Write-ColorOutput "✓ Docker 已安装" "Green"
} else {
    Write-ColorOutput "✗ 错误: 未找到 Docker" "Red"
    Write-ColorOutput "请先安装 Docker: https://www.docker.com/" "Yellow"
    exit 1
}

# 检查 Docker Compose
$composeCmd = $null
if (Test-CommandExists "docker-compose") {
    $composeCmd = "docker-compose"
    Write-ColorOutput "✓ Docker Compose 已安装" "Green"
} else {
    try {
        docker compose version | Out-Null
        $composeCmd = "docker compose"
        Write-ColorOutput "✓ Docker Compose (插件) 已安装" "Green"
    } catch {
        Write-ColorOutput "✗ 错误: 未找到 docker-compose 或 docker compose" "Red"
        Write-ColorOutput "请先安装 Docker Compose" "Yellow"
        exit 1
    }
}

Write-Host ""

# 步骤 2: 配置安装目录
Write-Step -Current 2 -Total 5 -Message "配置安装目录"
Write-Host ""

Write-ColorOutput "将从仓库克隆代码: $DEFAULT_REPO" "Cyan"
Write-ColorOutput "使用分支: $DEFAULT_BRANCH" "Cyan"
Write-Host ""

$installDir = Read-UserInput -Prompt "请输入安装目录名称" -DefaultValue $DEFAULT_INSTALL_DIR -Required $false

Write-Host ""

# 检查目录是否已存在
if (Test-Path $installDir) {
    Write-ColorOutput "⚠ 警告: 目录 '$installDir' 已存在！" "Yellow"
    $overwrite = Read-UserInput -Prompt "是否删除并重新安装? (y/n)" -DefaultValue "n" -Required $false
    if ($overwrite -eq "y" -or $overwrite -eq "Y") {
        Write-ColorOutput "正在删除旧目录..." "Yellow"
        Remove-Item -Path $installDir -Recurse -Force
        Write-ColorOutput "✓ 旧目录已删除" "Green"
    } else {
        Write-ColorOutput "安装已取消。" "Yellow"
        exit 0
    }
}

# 步骤 3: 克隆仓库
Write-Step -Current 3 -Total 5 -Message "克隆项目代码"
Write-Host ""

Write-ColorOutput "正在从 $DEFAULT_REPO 克隆代码..." "Cyan"
try {
    git clone -b $DEFAULT_BRANCH $DEFAULT_REPO $installDir 2>&1 | Out-Null
    Write-ColorOutput "✓ 代码克隆成功" "Green"
} catch {
    Write-ColorOutput "✗ 克隆失败: $($_.Exception.Message)" "Red"
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

# 步骤 4: 配置 Azure Speech Service
Write-Step -Current 4 -Total 5 -Message "配置 Azure Speech Service"
Write-Host ""

Write-ColorOutput "请访问 Azure Portal 获取以下信息：" "Cyan"
Write-ColorOutput "1. 登录: https://portal.azure.com" "White"
Write-ColorOutput "2. 搜索并创建 'Speech Services' 资源" "White"
Write-ColorOutput "3. 在'密钥和终结点'页面获取密钥和区域" "White"
Write-Host ""

# 获取 SPEECH_KEY
$speechKey = Read-UserInput -Prompt "请输入 Azure Speech Service 密钥" -Required $true

# 获取 SPEECH_REGION
Write-Host ""
Write-ColorOutput "请选择 Azure Speech Service 区域：" "Cyan"
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

# 验证连接
Write-Host ""
$testConnection = Read-UserInput -Prompt "是否验证连接? (y/n)" -DefaultValue "y" -Required $false
if ($testConnection -eq "y" -or $testConnection -eq "Y") {
    $isValid = Test-AzureConnection -Key $speechKey -Region $speechRegion
    if (-not $isValid) {
        Write-Host ""
        $continueInstall = Read-UserInput -Prompt "连接验证失败，是否继续安装? (y/n)" -DefaultValue "n" -Required $false
        if ($continueInstall -ne "y" -and $continueInstall -ne "Y") {
            Write-ColorOutput "安装已取消。" "Yellow"
            exit 1
        }
    }
}

# 配额限制配置
Write-Host ""
Write-ColorOutput "配额限制配置 (使用默认值)" "Cyan"
$sttLimit = "18000"
$ttsLimit = "500000"
$pronLimit = "18000"

$configureLimits = Read-UserInput -Prompt "是否自定义配额限制? (y/n)" -DefaultValue "n" -Required $false
if ($configureLimits -eq "y" -or $configureLimits -eq "Y") {
    Write-Host ""
    $sttLimit = Read-UserInput -Prompt "STT 每月秒数限制" -DefaultValue "18000" -Required $false
    $ttsLimit = Read-UserInput -Prompt "TTS 每月字符数限制" -DefaultValue "500000" -Required $false
    $pronLimit = Read-UserInput -Prompt "发音评估每月秒数限制" -DefaultValue "18000" -Required $false
}

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
    Write-ColorOutput "✓ 配置文件已生成" "Green"
} catch {
    Write-ColorOutput "✗ 保存配置文件失败: $($_.Exception.Message)" "Red"
    exit 1
}

Write-Host ""

# 步骤 5: 启动服务
Write-Step -Current 5 -Total 5 -Message "启动 Docker 服务"
Write-Host ""

$startService = Read-UserInput -Prompt "是否立即启动服务? (y/n)" -DefaultValue "y" -Required $false
if ($startService -eq "y" -or $startService -eq "Y") {
    Write-ColorOutput "正在构建并启动服务..." "Cyan"
    Write-Host ""
    
    try {
        if ($composeCmd -eq "docker-compose") {
            docker-compose up -d --build
        } else {
            docker compose up -d --build
        }
        Write-Host ""
        Write-ColorOutput "✓ 服务启动成功！" "Green"
    } catch {
        Write-Host ""
        Write-ColorOutput "✗ 服务启动失败: $($_.Exception.Message)" "Red"
        Write-ColorOutput "请检查 Docker 日志: $composeCmd logs" "Yellow"
        exit 1
    }
} else {
    Write-ColorOutput "跳过服务启动。" "Yellow"
    Write-Host ""
    Write-ColorOutput "稍后可以使用以下命令启动服务：" "Cyan"
    Write-ColorOutput "  cd $((Get-Location).Path)" "White"
    Write-ColorOutput "  $composeCmd up -d --build" "White"
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
}

Write-ColorOutput "常用命令：" "Cyan"
Write-ColorOutput "  • 查看日志: $composeCmd logs -f" "White"
Write-ColorOutput "  • 停止服务: $composeCmd down" "White"
Write-ColorOutput "  • 重启服务: $composeCmd restart" "White"
Write-ColorOutput "  • 查看状态: $composeCmd ps" "White"
Write-Host ""

Write-ColorOutput "祝您使用愉快！🚀" "Green"
Write-Host ""
