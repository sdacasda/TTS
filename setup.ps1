#!/usr/bin/env pwsh
# Azure Speech Service 交互式配置脚本
# 用于引导用户配置 .env 文件

# 设置控制台输出编码为 UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

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

function Test-AzureConnection {
    param(
        [string]$Key,
        [string]$Region
    )
    
    Write-ColorOutput "正在验证 Azure Speech Service 连接..." "Yellow"
    
    $url = "https://$Region.tts.speech.microsoft.com/cognitiveservices/voices/list"
    $headers = @{
        "Ocp-Apim-Subscription-Key" = $Key
        "User-Agent" = "speech-portal-setup"
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

Write-Header "Azure Speech Service 配置向导"

Write-ColorOutput "欢迎使用 Azure Speech Service 门户配置向导！" "Green"
Write-Host ""
Write-ColorOutput "本向导将帮助您配置 Azure Speech Service 所需的环境变量。" "White"
Write-Host ""

# 检查是否已存在 .env 文件
$envPath = Join-Path $PSScriptRoot ".env"
if (Test-Path $envPath) {
    Write-ColorOutput "⚠ 警告: .env 文件已存在！" "Yellow"
    Write-Host ""
    $overwrite = Read-UserInput -Prompt "是否要覆盖现有配置? (y/n)" -DefaultValue "n" -Required $false
    if ($overwrite -ne "y" -and $overwrite -ne "Y") {
        Write-ColorOutput "配置已取消。" "Yellow"
        exit 0
    }
    Write-Host ""
}

Write-Header "步骤 1: Azure Speech Service 配置"

Write-ColorOutput "如需获取密钥，请访问: https://portal.azure.com (Speech Services > 密钥和终结点)" "Cyan"
Write-Host ""

# 获取 SPEECH_KEY
$speechKey = Read-UserInput -Prompt "请输入 Azure Speech Service 密钥 (KEY1 或 KEY2)" -Required $true

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
        $continue = Read-UserInput -Prompt "连接验证失败，是否仍要继续保存配置? (y/n)" -DefaultValue "n" -Required $false
        if ($continue -ne "y" -and $continue -ne "Y") {
            Write-ColorOutput "配置已取消。" "Yellow"
            exit 1
        }
    }
}

Write-Host ""
Write-Header "步骤 2: 配额限制配置 (可选)"

Write-ColorOutput "Azure Speech Free (F0) 层每月免费额度：" "Cyan"
Write-ColorOutput "  - STT (语音转文本): 5小时 = 18000秒" "White"
Write-ColorOutput "  - TTS (文本转语音): 500,000字符" "White"
Write-ColorOutput "  - 发音评估: 5小时 = 18000秒" "White"
Write-Host ""

$useLimits = Read-UserInput -Prompt "是否配置配额限制? (y/n)" -DefaultValue "n" -Required $false

if ($useLimits -eq "y" -or $useLimits -eq "Y") {
    Write-Host ""
    $sttLimit = Read-UserInput -Prompt "STT 每月秒数限制" -DefaultValue "18000" -Required $false
    $ttsLimit = Read-UserInput -Prompt "TTS 每月字符数限制" -DefaultValue "500000" -Required $false
    $pronLimit = Read-UserInput -Prompt "发音评估每月秒数限制" -DefaultValue "18000" -Required $false
} else {
    $sttLimit = "18000"
    $ttsLimit = "500000"
    $pronLimit = "18000"
}

# 生成 .env 文件内容
Write-Host ""
Write-Header "生成配置文件"

$envContent = @"
# ============================================
# Azure Speech Service 配置
# ============================================
# 生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

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
    $envContent | Out-File -FilePath $envPath -Encoding UTF8 -NoNewline
    Write-ColorOutput "✓ 配置文件已成功保存到: $envPath" "Green"
} catch {
    Write-ColorOutput "✗ 保存配置文件失败: $($_.Exception.Message)" "Red"
    exit 1
}

# 显示摘要
Write-Host ""
Write-Header "配置摘要"

Write-ColorOutput "密钥: $($speechKey.Substring(0, 8))..." "White"
Write-ColorOutput "区域: $speechRegion" "White"
Write-ColorOutput "STT 限制: $sttLimit 秒" "White"
Write-ColorOutput "TTS 限制: $ttsLimit 字符" "White"
Write-ColorOutput "发音评估限制: $pronLimit 秒" "White"

Write-Host ""
Write-Header "下一步操作"

Write-ColorOutput "配置已完成！您现在可以：" "Green"
Write-Host ""
Write-ColorOutput "1. 启动服务:" "Cyan"
Write-ColorOutput "   docker compose up -d --build" "White"
Write-Host ""
Write-ColorOutput "2. 访问服务:" "Cyan"
Write-ColorOutput "   http://localhost:8000" "White"
Write-Host ""
Write-ColorOutput "3. 查看日志:" "Cyan"
Write-ColorOutput "   docker compose logs -f" "White"
Write-Host ""

Write-ColorOutput "祝您使用愉快！🎉" "Green"
Write-Host ""
