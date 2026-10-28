# 检查包边界。Odin 没有 Go 的 internal 机制，只能靠构建期脚本约束。
# 用法：
#   tools/check-deps.ps1              正常检查
#   tools/check-deps.ps1 -SelfTest    反向用例（临时加一条禁止 import，期望失败）

param(
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$script:fail = $false

function Fail-Check($message) {
    Write-Host "check-deps: $message" -ForegroundColor Red
    $script:fail = $true
}

function Test-ImportRules {
    foreach ($dir in @("ap-web", "ap-tui")) {
        Get-ChildItem "$dir/*.odin" -ErrorAction SilentlyContinue | ForEach-Object {
            $file = $_.FullName
            Get-Content $file | ForEach-Object {
                if ($_ -match '^\s*import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"') {
                    $path = $Matches[1]
                    if ($path -notmatch '^(core:|base:|vendor:|\.\./ap-core/client$|\.\./ap-core/protocol$)') {
                        Fail-Check ('{0}: 前端不允许 import "{1}"（只允许 ap-core/client、ap-core/protocol）' -f $file, $path)
                    }
                }
            }
        }
    }

    Get-ChildItem "ap-core/client/*.odin" -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_.FullName
        Get-Content $file | ForEach-Object {
            if ($_ -match '^\s*import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"') {
                $path = $Matches[1]
                if ($path -notmatch '^(core:|base:|vendor:|\.\./platform$|\.\./protocol$)') {
                    Fail-Check ('{0}: ap-core/client 不允许 import "{1}"（只允许 ap-core/platform、ap-core/protocol）' -f $file, $path)
                }
            }
        }
    }

    Get-ChildItem "ap-core/engine/*.odin" -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_.FullName
        Get-Content $file | ForEach-Object {
            if ($_ -match '^\s*import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"') {
                $path = $Matches[1]
                if ($path -notmatch '^(core:|base:|vendor:|\.\./platform$|\.\./protocol$)') {
                    Fail-Check ('{0}: ap-core/engine 不允许 import "{1}"' -f $file, $path)
                }
            }
        }
    }

    foreach ($dir in @("ap-core/platform", "ap-core/protocol")) {
        Get-ChildItem "$dir/*.odin" -ErrorAction SilentlyContinue | ForEach-Object {
            $file = $_.FullName
            Get-Content $file | ForEach-Object {
                if ($_ -match '^\s*import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"') {
                    $path = $Matches[1]
                    if ($path -notmatch '^(core:|base:|vendor:)') {
                        Fail-Check ('{0}: {1} 不允许 import 本地包 "{2}"' -f $file, $dir, $path)
                    }
                }
            }
        }
    }

    Get-ChildItem "ap-core/*.odin" -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_.FullName
        Get-Content $file | ForEach-Object {
            if ($_ -match '^\s*import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"') {
                $path = $Matches[1]
                if ($path -notmatch '^(core:|base:|vendor:|engine$|platform$|protocol$)') {
                    Fail-Check ('{0}: apcore 根包不允许 import "{1}"' -f $file, $path)
                }
            }
        }
    }

    $apSources = Get-ChildItem "ap-core/*.odin" -ErrorAction SilentlyContinue | ForEach-Object {
        Get-Content $_.FullName -Raw
    }
    if (($apSources -join "`n") -match '(?m)^main\s*::\s*proc') {
        Fail-Check "apcore 根包不允许定义 main（入口在 cmd/ap）"
    }

    # cmd/* 是薄入口：只能 import 对应的库包与 apcore。
    Get-ChildItem "cmd/*/*.odin" -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_.FullName
        Get-Content $file | ForEach-Object {
            if ($_ -match '^\s*import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"') {
                $path = $Matches[1]
                if ($path -notmatch '^(core:|base:|vendor:|\.\./\.\./ap-core$|\.\./\.\./ap-tui$|\.\./\.\./ap-web$)') {
                    Fail-Check ('{0}: cmd 入口只允许 import "../../ap-core"、"../../ap-tui"、"../../ap-web"' -f $file)
                }
            }
        }
    }
}

function Test-ImportRules-Bool {
    $script:fail = $false
    Test-ImportRules
    return -not $script:fail
}

if ($SelfTest) {
    $probe = "ap-web/__check_deps_probe.odin"
    Set-Content -Path $probe -Value "package apweb`n`nimport `"../ap-core/engine`"" -Encoding utf8
    $ok = Test-ImportRules-Bool
    Remove-Item $probe -Force
    if ($ok) {
        Write-Host "check-deps: self-test 失败：禁止 import 没有被检出" -ForegroundColor Red
        exit 1
    }

    $probe = "cmd/ap-web/__check_deps_probe.odin"
    Set-Content -Path $probe -Value "package main`n`nimport `"../../ap-core/engine`"" -Encoding utf8
    $ok = Test-ImportRules-Bool
    Remove-Item $probe -Force
    if ($ok) {
        Write-Host "check-deps: self-test 失败：cmd 入口的禁止 import 没有被检出" -ForegroundColor Red
        exit 1
    }
    Write-Host "check-deps: self-test 通过"
    exit 0
}

Test-ImportRules

$tmpdir = Join-Path $env:TEMP "ap-check-deps-$PID"
New-Item -ItemType Directory -Force $tmpdir | Out-Null
try {
    foreach ($name in @("ap-web", "ap-tui")) {
        $dir = "cmd/$name"
        $json = Join-Path $tmpdir "$name.json"
        $exe = Join-Path $tmpdir "$name.exe"
        & odin build $dir -out:$exe -export-dependencies:json -export-dependencies-file:$json | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail-Check "odin build $dir 失败"
            continue
        }
        $deps = Get-Content $json -Raw | ConvertFrom-Json
        foreach ($source in $deps.source_files) {
            if ($source -match '[\\/]ap-core[\\/]engine[\\/]') {
                Fail-Check "$dir 的编译文件里出现了 ap-core/engine/（agent 被链进前端）：$source"
            }
        }
    }
} finally {
    Remove-Item $tmpdir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail) {
    exit 1
}
Write-Host "check-deps: ok"
