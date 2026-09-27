function Repair-SymphonyWorkspaces {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    $resolvedRoot = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $ancestor = Get-Item -LiteralPath $resolvedRoot
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing workspace recovery through a link: $($ancestor.FullName)"
        }
        $ancestor = $ancestor.Parent
    }
    foreach ($directory in Get-ChildItem -LiteralPath $resolvedRoot -Directory -Force) {
        if ($directory.Name -notmatch '^GH-[0-9]+$') { continue }
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing workspace recovery through a link: $($directory.FullName)"
        }
        $workspace = [IO.Path]::GetFullPath($directory.FullName)
        if (-not $workspace.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Workspace escapes configured root: $workspace"
        }
        $marker = $workspace + '.initializing'
        $empty = @(Get-ChildItem -LiteralPath $workspace -Force).Count -eq 0
        if ((Test-Path -LiteralPath $marker) -or $empty) {
            $topLevel = & git -C $workspace rev-parse --show-toplevel 2>$null
            $validRoot = $LASTEXITCODE -eq 0 -and $topLevel -and
                ([IO.Path]::GetFullPath($topLevel) -eq $workspace)
            & git -C $workspace rev-parse --verify HEAD *> $null
            $validCheckout = $validRoot -and $LASTEXITCODE -eq 0
            if (-not $validCheckout) {
                $links = Get-ChildItem -LiteralPath $workspace -Force -Recurse -Attributes ReparsePoint
                if ($links) { throw "Refusing to remove workspace containing links: $workspace" }
                Write-Host "Removing abandoned workspace setup: $workspace"
                Remove-Item -LiteralPath $workspace -Recurse -Force
                if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
            }
        } elseif (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) {
            Write-Warning "Unrecognized non-Git workspace preserved for inspection: $workspace"
        }
    }
}
