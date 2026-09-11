param(
    [string]$ResultsPath,
    [switch]$PrintFingerprint
)

$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$contractPath = Join-Path $skillRoot 'tests/behavior-contract.json'
$defaultResultsPath = Join-Path $skillRoot 'tests/latest-forward-test-results.json'
$validationErrors = New-Object 'System.Collections.Generic.List[string]'

function Add-ValidationError {
    param([string]$Message)
    $script:validationErrors.Add($Message)
}

function Get-SkillSourceFingerprint {
    $excludedResultPath = [System.IO.Path]::GetFullPath($defaultResultsPath)
    $normalizedSkillRoot = [System.IO.Path]::GetFullPath($skillRoot).TrimEnd('\', '/') +
        [System.IO.Path]::DirectorySeparatorChar
    $sourceFiles = Get-ChildItem -LiteralPath $skillRoot -Recurse -File | Where-Object {
        $_.FullName -notmatch '[\\/]backups[\\/]' -and
        [System.IO.Path]::GetFullPath($_.FullName) -ne $excludedResultPath
    } | Sort-Object FullName

    $fingerprintSource = New-Object System.Text.StringBuilder
    foreach ($file in $sourceFiles) {
        $normalizedFilePath = [System.IO.Path]::GetFullPath($file.FullName)
        $relativePath = $normalizedFilePath.Substring($normalizedSkillRoot.Length).Replace('\', '/')
        $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
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

$sourceFingerprint = Get-SkillSourceFingerprint
if ($PrintFingerprint) {
    Write-Output $sourceFingerprint
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
    $ResultsPath = $defaultResultsPath
}

try {
    $resolvedResultsPath = (Resolve-Path -LiteralPath $ResultsPath -ErrorAction Stop).Path
}
catch {
    Write-Error "Cannot resolve forward-test results: $($_.Exception.Message)"
    exit 1
}

if ((Get-Item -LiteralPath $resolvedResultsPath).Length -gt 5MB) {
    Write-Error 'Forward-test results file exceeds 5 MB'
    exit 1
}

try {
    $contract = Get-Content -LiteralPath $contractPath -Encoding UTF8 -Raw | ConvertFrom-Json
    $results = Get-Content -LiteralPath $resolvedResultsPath -Encoding UTF8 -Raw | ConvertFrom-Json
}
catch {
    Write-Error "Forward-test data is not valid UTF-8 JSON: $($_.Exception.Message)"
    exit 1
}

if ($results.version -ne 1) {
    Add-ValidationError 'Forward-test results version must be 1'
}
if ($results.contract_version -ne $contract.version) {
    Add-ValidationError 'Forward-test contract version mismatch'
}
if ($results.skill_source_fingerprint -ne $sourceFingerprint) {
    Add-ValidationError 'Forward-test results do not match the current skill source fingerprint'
}

$contractById = @{}
foreach ($case in @($contract.cases)) {
    $contractById[$case.id] = $case
}

$runs = @($results.runs)
$runIds = @($runs | ForEach-Object { $_.id })
$duplicateRuns = $runIds | Group-Object | Where-Object Count -gt 1
foreach ($duplicate in $duplicateRuns) {
    Add-ValidationError "Duplicate forward-test run: $($duplicate.Name)"
}

$coveredTags = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($run in $runs) {
    if (-not $contractById.ContainsKey($run.id)) {
        Add-ValidationError "Unknown forward-test case: $($run.id)"
        continue
    }

    $case = $contractById[$run.id]
    foreach ($tag in @($case.tags)) {
        [void]$coveredTags.Add([string]$tag)
    }

    if ($run.independent_context -ne $true) {
        Add-ValidationError "Forward-test $($run.id) was not run in an independent context"
    }
    if ([string]::IsNullOrWhiteSpace($run.raw_output)) {
        Add-ValidationError "Forward-test $($run.id) has no raw output"
    }
    if ($run.question_count -lt 0 -or
        $run.question_count -gt $case.max_business_questions_per_round) {
        Add-ValidationError "Forward-test $($run.id) exceeds its question limit"
    }
    if (@($run.external_actions).Count -gt 0) {
        Add-ValidationError "Forward-test $($run.id) performed external actions"
    }
    if ($case.mutation -eq 'forbidden' -and @($run.files_modified).Count -gt 0) {
        Add-ValidationError "Forward-test $($run.id) modified files despite a forbidden mutation policy"
    }
    if ($case.project_access -eq 'none' -and @($run.project_files_read).Count -gt 0) {
        Add-ValidationError "Forward-test $($run.id) read project files despite project_access=none"
    }
    if (@($run.project_files_read).Count -gt 0 -and $run.project_consent_before_read -ne $true) {
        Add-ValidationError "Forward-test $($run.id) read project files before consent"
    }
    if ($case.project_access -eq 'safe-readonly' -and
        @($run.project_files_read).Count -gt 0 -and
        $run.safe_manifest_used -ne $true) {
        Add-ValidationError "Forward-test $($run.id) did not use the safe file manifest"
    }

    $assertionsByCode = @{}
    foreach ($assertion in @($run.expected_assertions)) {
        $assertionsByCode[$assertion.code] = $assertion
    }
    foreach ($expectedCode in @($case.expected_behaviors)) {
        if (-not $assertionsByCode.ContainsKey($expectedCode) -or
            $assertionsByCode[$expectedCode].passed -ne $true -or
            [string]::IsNullOrWhiteSpace($assertionsByCode[$expectedCode].evidence)) {
            Add-ValidationError "Forward-test $($run.id) lacks passing evidence for $expectedCode"
        }
    }

    $forbiddenObserved = @($run.forbidden_observations)
    if ($forbiddenObserved.Count -gt 0) {
        Add-ValidationError "Forward-test $($run.id) observed forbidden behavior: $($forbiddenObserved -join ', ')"
    }
}

foreach ($requiredCoverageTag in @('non-ui-carrier', 'risk-based-demo', 'post-delivery-choice')) {
    if (-not $coveredTags.Contains($requiredCoverageTag)) {
        Add-ValidationError "Forward-test results are missing required coverage: $requiredCoverageTag"
    }
}

if ($validationErrors.Count -gt 0) {
    $validationErrors | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output "FORWARD_TEST_RESULTS_OK runs=$($runs.Count) fingerprint=$sourceFingerprint"
