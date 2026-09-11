param(
    [Parameter(Mandatory = $true)]
    [string]$PythonPath,

    [Parameter(Mandatory = $true)]
    [string]$QuickValidatePath,

    [Parameter(Mandatory = $true)]
    [string]$PyYamlPackagePath,

    [Parameter(Mandatory = $true)]
    [string]$BehaviorResultsPath
)

$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$behaviorValidatorPath = Join-Path $PSScriptRoot 'validate-behavior-contract.ps1'
$forwardTestValidatorPath = Join-Path $PSScriptRoot 'validate-forward-test-results.ps1'
$skillValidatorPath = Join-Path $PSScriptRoot 'validate-skill.ps1'
$safeManifestPath = Join-Path $PSScriptRoot 'build-safe-file-manifest.py'
$pinnedQuickValidateRunnerPath = Join-Path $PSScriptRoot 'run-pinned-quick-validate.py'
$trustedToolsPath = Join-Path $skillRoot 'tests/trusted-tools.json'

function Get-DirectoryFingerprint {
    param([string]$DirectoryPath)

    $normalizedRoot = [System.IO.Path]::GetFullPath($DirectoryPath).TrimEnd('\', '/') +
        [System.IO.Path]::DirectorySeparatorChar
    $fingerprintSource = New-Object System.Text.StringBuilder
    Get-ChildItem -LiteralPath $DirectoryPath -Recurse -File |
        Where-Object {
            $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and
            $_.Extension -notin @('.pyc', '.pyo')
        } |
        Sort-Object FullName |
        ForEach-Object {
        $normalizedFilePath = [System.IO.Path]::GetFullPath($_.FullName)
        $relativePath = $normalizedFilePath.Substring($normalizedRoot.Length).Replace('\', '/')
        $fileHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        [void]$fingerprintSource.AppendLine("$relativePath`:$fileHash")
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintSource.ToString())
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '')
}

try {
    $resolvedPythonPath = (Resolve-Path -LiteralPath $PythonPath -ErrorAction Stop).Path
    $resolvedQuickValidatePath = (Resolve-Path -LiteralPath $QuickValidatePath -ErrorAction Stop).Path
    $resolvedPyYamlPackagePath = (Resolve-Path -LiteralPath $PyYamlPackagePath -ErrorAction Stop).Path
    $trustedTools = Get-Content -LiteralPath $trustedToolsPath -Encoding UTF8 -Raw | ConvertFrom-Json
}
catch {
    Write-Error "Cannot resolve trusted validation tools: $($_.Exception.Message)"
    exit 1
}

if (-not (Test-Path -LiteralPath $resolvedPythonPath -PathType Leaf) -or
    [System.IO.Path]::GetExtension($resolvedPythonPath) -ne '.exe') {
    Write-Error 'PythonPath must resolve to an explicit .exe file'
    exit 1
}

$pythonSignature = Get-AuthenticodeSignature -LiteralPath $resolvedPythonPath
if ($pythonSignature.Status -ne 'Valid') {
    Write-Error "Python executable does not have a valid Authenticode signature: $resolvedPythonPath"
    exit 1
}

if (-not (Test-Path -LiteralPath $resolvedQuickValidatePath -PathType Leaf) -or
    [System.IO.Path]::GetExtension($resolvedQuickValidatePath) -ne '.py') {
    Write-Error 'QuickValidatePath must resolve to an explicit .py file'
    exit 1
}

$pyYamlInitPath = Join-Path $resolvedPyYamlPackagePath '__init__.py'
if (-not (Test-Path -LiteralPath $resolvedPyYamlPackagePath -PathType Container) -or
    -not (Test-Path -LiteralPath $pyYamlInitPath -PathType Leaf) -or
    (Split-Path -Leaf $resolvedPyYamlPackagePath) -ne 'yaml') {
    Write-Error 'PyYamlPackagePath must resolve to an explicit yaml package directory'
    exit 1
}

$expectedHash = [string]$trustedTools.tools.skill_creator_quick_validate.sha256
if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
    Write-Error 'Trusted quick_validate.py SHA-256 is invalid'
    exit 1
}

$actualHash = (Get-FileHash -LiteralPath $resolvedQuickValidatePath -Algorithm SHA256).Hash
if ($actualHash -ne $expectedHash) {
    Write-Error "quick_validate.py hash mismatch. Expected $expectedHash but found $actualHash"
    exit 1
}

$expectedPyYamlHash = [string]$trustedTools.tools.pyyaml_package.sha256
if ($expectedPyYamlHash -notmatch '^[A-Fa-f0-9]{64}$') {
    Write-Error 'Trusted PyYAML package SHA-256 is invalid'
    exit 1
}
$actualPyYamlHash = Get-DirectoryFingerprint -DirectoryPath $resolvedPyYamlPackagePath
if ($actualPyYamlHash -ne $expectedPyYamlHash) {
    Write-Error "PyYAML package hash mismatch. Expected $expectedPyYamlHash but found $actualPyYamlHash"
    exit 1
}

& $behaviorValidatorPath
& $skillValidatorPath
& $forwardTestValidatorPath -ResultsPath $BehaviorResultsPath

$env:PYTHONUTF8 = '1'
$safeManifestSelfTest = & $resolvedPythonPath -I -X utf8 $safeManifestPath `
    --project-root $skillRoot `
    --candidate 'SKILL.md' `
    --candidate '..\outside-project-scope'
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
$safeManifestResult = $safeManifestSelfTest | ConvertFrom-Json
if (@($safeManifestResult.allowed).Count -ne 1 -or
    @($safeManifestResult.blocked | Where-Object reason -eq 'outside-project-root').Count -ne 1) {
    Write-Error 'Safe file manifest self-test failed'
    exit 1
}

& $resolvedPythonPath -I -X utf8 $pinnedQuickValidateRunnerPath `
    --pyyaml-package $resolvedPyYamlPackagePath `
    --quick-validate $resolvedQuickValidatePath `
    --skill-root $skillRoot
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Output "RELEASE_VALIDATION_OK skill=$skillRoot quick_validate_sha256=$actualHash pyyaml_sha256=$actualPyYamlHash"
