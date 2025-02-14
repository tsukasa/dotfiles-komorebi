param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath
)

# Get the directory where the script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Validate the repository path exists and is a git repository
if (-not (Test-Path -Path $RepoPath)) {
    Write-Error "The specified path '$RepoPath' does not exist."
    exit 1
}

if (-not (Test-Path -Path (Join-Path -Path $RepoPath -ChildPath ".git"))) {
    Write-Error "The specified path '$RepoPath' is not a git repository."
    exit 1
}

# Find all .patch files in the script directory
$patchFiles = Get-ChildItem -Path $scriptDir -Filter "*.patch" | Sort-Object Name

if ($patchFiles.Count -eq 0) {
    Write-Warning "No patch files found in '$scriptDir'."
    exit 0
}

Write-Host "Found $($patchFiles.Count) patch files to apply..."

# Set working directory to the git repository
Push-Location $RepoPath

try {
    foreach ($patch in $patchFiles) {
        Write-Host "Applying patch: $($patch.Name)" -ForegroundColor Cyan
        
        # Use git apply to apply the patch
        $output = git apply --check "$($patch.FullName)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            git apply "$($patch.FullName)" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Successfully applied patch" -ForegroundColor Green
            }
            else {
                Write-Error "  ✗ Failed to apply patch: $($patch.Name)"
                exit 1
            }
        }
        else {
            Write-Error "  ✗ Patch check failed for $($patch.Name): $output"
            exit 1
        }
    }

    Write-Host "All patches applied successfully!" -ForegroundColor Green
}
finally {
    # Restore the original working directory
    Pop-Location
}
