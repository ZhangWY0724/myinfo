[CmdletBinding()]
param(
    [string]$ApifoxRoot = (Join-Path $env:APPDATA "apifox"),
    [string]$OutputPath = (Join-Path (Get-Location) ("apifox-ioc-report-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt"))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "==== $Title ====" -ForegroundColor Cyan
}

function Add-ReportLine {
    param([string]$Text)
    $script:Report.Add($Text) | Out-Null
}

function Read-BytesShared {
    param([string]$Path)

    $fileStream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )

    try {
        $buffer = New-Object byte[] $fileStream.Length
        [void]$fileStream.Read($buffer, 0, $buffer.Length)
        return ,$buffer
    }
    finally {
        $fileStream.Dispose()
    }
}

function Find-AsciiOffsets {
    param(
        [byte[]]$Bytes,
        [string]$Text
    )

    $pattern = [System.Text.Encoding]::ASCII.GetBytes($Text)
    $hits = New-Object System.Collections.Generic.List[int]

    for ($i = 0; $i -le $Bytes.Length - $pattern.Length; $i++) {
        $matched = $true
        for ($j = 0; $j -lt $pattern.Length; $j++) {
            if ($Bytes[$i + $j] -ne $pattern[$j]) {
                $matched = $false
                break
            }
        }

        if ($matched) {
            $hits.Add($i)
        }
    }

    return $hits
}

function Get-SafeSnippet {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [int]$Length = 200
    )

    $start = [Math]::Max(0, $Offset - 40)
    $count = [Math]::Min($Length, $Bytes.Length - $start)
    $snippet = [System.Text.Encoding]::ASCII.GetString($Bytes, $start, $count)
    $snippet = $snippet -replace '[^\x20-\x7E]', '.'
    $snippet = $snippet -replace '(Bearer\s+)[A-Za-z0-9\-\._~\+/]+=*', '$1<redacted>'
    $snippet = $snippet -replace '("common\.accessToken"\s*[:=]\s*")[^"]+(")', '$1<redacted>$2'
    if ($snippet.Length -gt 180) {
        $snippet = $snippet.Substring(0, 180) + "..."
    }
    return $snippet
}

function Test-LevelDbPattern {
    param(
        [string]$LevelDbPath,
        [string[]]$Patterns
    )

    $results = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path $LevelDbPath)) {
        return $results
    }

    $files = Get-ChildItem -Path (Join-Path $LevelDbPath "*") -File -Include "*.ldb", "*.log" -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        try {
            $bytes = Read-BytesShared -Path $file.FullName
        }
        catch {
            continue
        }

        foreach ($pattern in $Patterns) {
            $offsets = Find-AsciiOffsets -Bytes $bytes -Text $pattern
            foreach ($offset in $offsets) {
                $results.Add([PSCustomObject]@{
                    File          = $file.FullName
                    Name          = $file.Name
                    Pattern       = $pattern
                    LastWriteTime = $file.LastWriteTime
                    Offset        = $offset
                    Snippet       = Get-SafeSnippet -Bytes $bytes -Offset $offset
                })
            }
        }
    }

    return $results
}

function Get-StateHits {
    param(
        [string]$RootPath,
        [string[]]$Indicators
    )

    $results = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path $RootPath)) {
        return $results
    }

    $candidateFiles = Get-ChildItem -Path $RootPath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'state|State|Preferences' -or
            $_.DirectoryName -match 'Network'
        }

    foreach ($file in $candidateFiles) {
        try {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
        }
        catch {
            continue
        }

        foreach ($indicator in $Indicators) {
            if ($content -match [regex]::Escape($indicator)) {
                $results.Add([PSCustomObject]@{
                    File          = $file.FullName
                    Indicator     = $indicator
                    LastWriteTime = $file.LastWriteTime
                })
            }
        }
    }

    return $results
}

function Get-PrefetchHits {
    $prefetchDir = Join-Path $env:SystemRoot "Prefetch"
    if (-not (Test-Path $prefetchDir)) {
        return @()
    }

    return Get-ChildItem -Path $prefetchDir -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "APIFOX*.pf" -or $_.Name -like "TASKLIST*.pf" } |
        Sort-Object LastWriteTime -Descending
}

function Get-SshInventory {
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    if (-not (Test-Path $sshDir)) {
        return @()
    }

    return Get-ChildItem -Path $sshDir -Force -File -ErrorAction SilentlyContinue |
        Select-Object FullName, Name, Length, LastWriteTime, LastAccessTime
}

function Get-DnsCacheHit {
    try {
        $dnsOutput = ipconfig /displaydns | Out-String
        if ($dnsOutput -match 'apifox\.it\.com') {
            return $true
        }
    }
    catch {
    }

    return $false
}

$Report = New-Object System.Collections.Generic.List[string]
$levelDbPatterns = @("_rl_headers", "_rl_mc", "common.accessToken")
$stateIndicators = @(
    "apifox.it.com",
    "/public/apifox-event.js",
    "/event/0/log"
)
$levelDbPath = Join-Path $ApifoxRoot "Local Storage/leveldb"
$apifoxProcess = Get-Process -Name "Apifox" -ErrorAction SilentlyContinue
$levelDbHits = @(Test-LevelDbPattern -LevelDbPath $levelDbPath -Patterns $levelDbPatterns)
$stateHits = @(Get-StateHits -RootPath $ApifoxRoot -Indicators $stateIndicators)
$prefetchHits = @(Get-PrefetchHits)
$sshInventory = @(Get-SshInventory)
$dnsCacheHit = Get-DnsCacheHit
$levelDbPatternsFound = @($levelDbHits | ForEach-Object { $_.Pattern })
$stateIndicatorsFound = @($stateHits | ForEach-Object { $_.Indicator })
$prefetchNamesFound = @($prefetchHits | ForEach-Object { $_.Name })

$score = 0
if ($levelDbPatternsFound -contains "_rl_headers") { $score += 3 }
if ($levelDbPatternsFound -contains "_rl_mc") { $score += 2 }
if ($stateIndicatorsFound -contains "apifox.it.com") { $score += 3 }
if (@($prefetchNamesFound | Where-Object { $_ -like "TASKLIST*.pf" }).Count -gt 0) { $score += 1 }
if ($sshInventory.Count -gt 0) { $score += 1 }

$riskLevel = switch ($score) {
    { $_ -ge 6 } { "HIGH" ; break }
    { $_ -ge 3 } { "MEDIUM" ; break }
    default { "LOW" }
}
$riskLevelMap = @{
    HIGH   = "高"
    MEDIUM = "中"
    LOW    = "低"
}
$riskLevelDisplay = $riskLevelMap[$riskLevel]

Write-Section "Apifox IOC 排查"
Write-Host ("Apifox 数据目录: " + $ApifoxRoot)
Write-Host ("报告输出路径: " + $OutputPath)
if ($apifoxProcess) {
    Write-Host "检测到 Apifox 正在运行，部分 LevelDB 文件可能被占用。" -ForegroundColor Yellow
}

Add-ReportLine "Apifox IOC 排查"
Add-ReportLine ("生成时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"))
Add-ReportLine ("Apifox 数据目录: " + $ApifoxRoot)
Add-ReportLine ("风险等级: " + $riskLevelDisplay)
Add-ReportLine ""

Write-Section "概要"
Write-Host ("风险等级: " + $riskLevelDisplay) -ForegroundColor Yellow
Add-ReportLine "概要"
Add-ReportLine ("- 风险等级: " + $riskLevelDisplay)
Add-ReportLine ("- Apifox 正在运行: " + [bool]$apifoxProcess)
Add-ReportLine ("- DNS 缓存命中 apifox.it.com: " + $dnsCacheHit)
Add-ReportLine ("- SSH 文件数量: " + $sshInventory.Count)
Add-ReportLine ("- Prefetch 命中数量: " + $prefetchHits.Count)
Add-ReportLine ("- LevelDB 命中数量: " + $levelDbHits.Count)
Add-ReportLine ("- State/Network 命中数量: " + $stateHits.Count)
Add-ReportLine ""

Write-Section "LevelDB 命中"
Add-ReportLine "LevelDB 命中"
if ($levelDbHits.Count -eq 0) {
    Write-Host "未在 LevelDB 中发现 _rl_headers / _rl_mc / common.accessToken 明文标记。"
    Add-ReportLine "- 无"
}
else {
    $levelDbHits |
        Sort-Object LastWriteTime, Name, Pattern |
        Select-Object `
            @{Name='文件';Expression={$_.Name}}, `
            @{Name='标记';Expression={$_.Pattern}}, `
            @{Name='最后写入时间';Expression={$_.LastWriteTime}}, `
            @{Name='偏移';Expression={$_.Offset}}, `
            @{Name='片段';Expression={$_.Snippet}} |
        Format-Table -Wrap -AutoSize

    foreach ($hit in $levelDbHits | Sort-Object LastWriteTime, Name, Pattern) {
        Add-ReportLine ("- 文件: " + $hit.File)
        Add-ReportLine ("  标记: " + $hit.Pattern)
        Add-ReportLine ("  最后写入时间: " + $hit.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
        Add-ReportLine ("  偏移: " + $hit.Offset)
        Add-ReportLine ("  片段: " + $hit.Snippet)
    }
}
Add-ReportLine ""

Write-Section "State / Network 命中"
Add-ReportLine "State / Network 命中"
if ($stateHits.Count -eq 0) {
    Write-Host "未在 state / Preferences 类文件中发现 IOC。"
    Add-ReportLine "- 无"
}
else {
    $stateHits |
        Sort-Object LastWriteTime, File, Indicator |
        Select-Object `
            @{Name='文件';Expression={$_.File}}, `
            @{Name='命中内容';Expression={$_.Indicator}}, `
            @{Name='最后写入时间';Expression={$_.LastWriteTime}} |
        Format-Table -Wrap -AutoSize

    foreach ($hit in $stateHits | Sort-Object LastWriteTime, File, Indicator) {
        Add-ReportLine ("- 文件: " + $hit.File)
        Add-ReportLine ("  命中内容: " + $hit.Indicator)
        Add-ReportLine ("  最后写入时间: " + $hit.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
    }
}
Add-ReportLine ""

Write-Section "SSH 文件清单"
Add-ReportLine "SSH 文件清单"
if ($sshInventory.Count -eq 0) {
    Write-Host ("未发现 " + $env:USERPROFILE + "/.ssh 下的文件。")
    Add-ReportLine "- 无"
}
else {
    $sshInventory | Select-Object `
        @{Name='文件名';Expression={$_.Name}}, `
        @{Name='大小';Expression={$_.Length}}, `
        @{Name='最后写入时间';Expression={$_.LastWriteTime}}, `
        @{Name='最后访问时间';Expression={$_.LastAccessTime}} |
        Format-Table -AutoSize
    foreach ($file in $sshInventory) {
        Add-ReportLine ("- 文件: " + $file.FullName)
        Add-ReportLine ("  大小: " + $file.Length)
        Add-ReportLine ("  最后写入时间: " + $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
        Add-ReportLine ("  最后访问时间: " + $file.LastAccessTime.ToString("yyyy-MM-dd HH:mm:ss"))
    }
}
Add-ReportLine ""

Write-Section "Prefetch 命中"
Add-ReportLine "Prefetch 命中"
if ($prefetchHits.Count -eq 0) {
    Write-Host "未发现 APIFOX / TASKLIST 的 Prefetch 记录。"
    Add-ReportLine "- 无"
}
else {
    $prefetchHits | Select-Object `
        @{Name='文件名';Expression={$_.Name}}, `
        @{Name='最后写入时间';Expression={$_.LastWriteTime}} |
        Format-Table -AutoSize
    foreach ($entry in $prefetchHits) {
        Add-ReportLine ("- 文件: " + $entry.FullName)
        Add-ReportLine ("  最后写入时间: " + $entry.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
    }
}
Add-ReportLine ""

Write-Section "处理建议"
$recommendations = @()
if ($riskLevel -eq "HIGH") {
    $recommendations += "立即修改 Apifox 密码，并在所有设备上重新登录。"
    $recommendations += "立即废弃并重建 %USERPROFILE%\\.ssh 下仍在使用的私钥。"
    $recommendations += "在 GitHub、GitLab、服务器和跳板机上替换旧公钥。"
}
elseif ($riskLevel -eq "MEDIUM") {
    $recommendations += "建议修改 Apifox 密码，并核查是否存在敏感私钥或令牌。"
    $recommendations += "继续在代理、EDR 或网关日志中检索 apifox.it.com。"
}
else {
    $recommendations += "当前本地 IOC 较弱，但如果你在 2026-03-04 到 2026-03-21 间运行过 Apifox，仍建议谨慎处理。"
}

if ($apifoxProcess) {
    $recommendations += "退出 Apifox 后重跑一次脚本，可减少因文件锁定导致的漏扫。"
}

foreach ($item in $recommendations) {
    Write-Host ("- " + $item)
    Add-ReportLine ("- " + $item)
}

$reportDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $reportDir)) {
    New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
}

$Report | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host ""
Write-Host ("报告已写入: " + $OutputPath) -ForegroundColor Green
