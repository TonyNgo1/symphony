# Portable PowerShell regression test; uses only an isolated temporary directory.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\recover_workspaces.ps1')
$taskTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$taskRoot = Join-Path $taskTempParent ('symphony-recovery-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $taskRoot | Out-Null

function Assert-Recovery([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
try {
    $empty = Join-Path $taskRoot 'GH-1'
    $partial = Join-Path $taskRoot 'GH-2'
    $valid = Join-Path $taskRoot 'GH-3'
    $unknown = Join-Path $taskRoot 'GH-4'
    foreach ($path in @($empty, $partial, $valid, $unknown)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
    Set-Content -LiteralPath ($partial + '.initializing') -Value 'setup interrupted'
    Set-Content -LiteralPath (Join-Path $partial 'partial-download') -Value 'not an agent edit'
    Set-Content -LiteralPath (Join-Path $unknown 'recoverable.txt') -Value 'keep'
    $handoffs = Join-Path $taskRoot '.symphony-recovery'
    New-Item -ItemType Directory -Path $handoffs | Out-Null
    $handoffFile = Join-Path $handoffs 'issue.json'
    Set-Content -LiteralPath $handoffFile -Value '{"thread_id":"keep","failures":2}'
    git -C $valid init --quiet
    git -C $valid -c user.name='Symphony test' -c user.email='test@example.invalid' commit --allow-empty -m 'test' --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Test repository setup failed' }
    Set-Content -LiteralPath ($valid + '.initializing') -Value 'stale marker after clone'
    Set-Content -LiteralPath (Join-Path $valid 'uncommitted.txt') -Value 'keep'
    Repair-SymphonyWorkspaces -WorkspaceRoot $taskRoot
    Assert-Recovery (-not (Test-Path -LiteralPath $empty)) 'Empty abandoned directory survived'
    Assert-Recovery (-not (Test-Path -LiteralPath $partial)) 'Interrupted setup survived'
    Assert-Recovery (-not (Test-Path -LiteralPath ($partial + '.initializing'))) 'Stale marker survived'
    Assert-Recovery (Test-Path -LiteralPath (Join-Path $valid 'uncommitted.txt')) 'Valid work was deleted'
    Assert-Recovery (Test-Path -LiteralPath (Join-Path $unknown 'recoverable.txt')) 'Unknown work was deleted'
    Assert-Recovery ((Get-Content -LiteralPath $handoffFile -Raw).Contains('"failures":2')) 'Durable handoff/counters were deleted during clone recovery'

    $outside = Join-Path $taskRoot 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'keep'
    $linked = Join-Path $taskRoot 'GH-5'
    New-Item -ItemType Junction -Path $linked -Target $outside | Out-Null
    $rejected = $false
    try { Repair-SymphonyWorkspaces -WorkspaceRoot $taskRoot } catch {
        $rejected = $_.Exception.Message -like '*through a link*'
    }
    Assert-Recovery $rejected 'Linked workspace was not rejected'
    Assert-Recovery (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) 'Link target was modified'
    Remove-Item -LiteralPath $linked -Force
    Write-Host 'Workspace recovery: 8 assertions passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($taskRoot)
    if (-not $resolved.StartsWith($taskTempParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike 'symphony-recovery-test-*') {
        throw 'Refusing unsafe test cleanup'
    }
    # Never follow links in cleanup if an assertion failed.
    Get-ChildItem -LiteralPath $resolved -Force -Attributes ReparsePoint |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
