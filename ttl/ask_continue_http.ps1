# ask_continue_http.ps1
# Direct HTTP call to ask_continue dialog, bypassing MCP limits
# Usage: .\ask_continue_http.ps1 -reason "task description" -workspace "d:/zmoney"

param(
    [Parameter(Mandatory=$true)]
    [string]$reason,
    
    [Parameter(Mandatory=$true)]
    [string]$workspace
)

# Fix UTF-8 encoding for Chinese characters
chcp 65001 | Out-Null
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

# Read port file
$portFile = Join-Path $workspace ".ask_continue_port"

if (-not (Test-Path $portFile)) {
    Write-Host "ERROR: Port file not found: $portFile"
    Write-Host "Please ensure Windsurf Continue Pro extension is running"
    exit 1
}

$port = Get-Content $portFile -Raw
$port = $port.Trim()

# Validate port number
if (-not ($port -match '^\d+$')) {
    Write-Host "ERROR: Invalid port: $port"
    exit 1
}

Write-Host "Connecting to port $port..."

# Build JSON-RPC request
$requestBody = @{
    jsonrpc = "2.0"
    id = [int](Get-Date -UFormat %s)
    method = "tools/call"
    params = @{
        name = "ask_continue"
        arguments = @{
            reason = $reason
            workspace = $workspace
        }
    }
} | ConvertTo-Json -Depth 10 -Compress

$url = "http://127.0.0.1:$port/"

try {
    # Convert request body to UTF-8 bytes
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($requestBody)
    
    # Send HTTP request with long timeout (10 minutes)
    # -UseBasicParsing improves compatibility on systems without IE
    $webResponse = Invoke-WebRequest -Uri $url -Method Post -Body $bodyBytes -ContentType "application/json; charset=utf-8" -TimeoutSec 600 -UseBasicParsing
    
    # Decode response as UTF-8
    $responseText = [System.Text.Encoding]::UTF8.GetString($webResponse.RawContentStream.ToArray())
    $response = $responseText | ConvertFrom-Json
    
    # Extract response content
    if ($response.result -and $response.result.content) {
        $content = $response.result.content
        $outputFile = Join-Path $workspace ".ask_continue_response.txt"
        $fullText = ""
        foreach ($item in $content) {
            if ($item.type -eq "text") {
                $fullText += $item.text
            }
        }
        
        # Write to file with UTF-8 no BOM
        [System.IO.File]::WriteAllText($outputFile, $fullText, [System.Text.Encoding]::UTF8)
        
        # Parse and format output
        $shouldContinue = ""
        $userInstruction = ""
        
        if ($fullText -match 'should_continue["\s:=]+(\w+)') {
            $shouldContinue = $Matches[1]
        }
        
        # Extract multi-line user instruction
        # Find "User instruction:" and extract everything until "Please continue" or end
        $instructionStart = $fullText.IndexOf("User instruction:")
        if ($instructionStart -ge 0) {
            $afterInstruction = $fullText.Substring($instructionStart + 17)  # 17 = length of "User instruction:"
            # Find the end marker
            $endMarker = $afterInstruction.IndexOf("Please continue")
            if ($endMarker -gt 0) {
                $userInstruction = $afterInstruction.Substring(0, $endMarker).Trim()
            } else {
                $userInstruction = $afterInstruction.Trim()
            }
        } elseif ($fullText -match 'user_instruction["\s:=]+([^"]+)') {
            $userInstruction = $Matches[1].Trim()
        }
        
        # Formatted output
        Write-Host "Result: should_continue=$shouldContinue"
        if ($userInstruction -ne "") {
            Write-Host "User instruction: $userInstruction"
        }
    } else {
        Write-Host "ERROR: Unexpected response format"
        Write-Host $responseText
    }
} catch {
    Write-Host "ERROR: HTTP request failed"
    Write-Host $_.Exception.Message
    exit 1
}
