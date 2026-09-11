$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$validationErrors = New-Object 'System.Collections.Generic.List[string]'

function Add-ValidationError {
    param([string]$Message)
    $script:validationErrors.Add($Message)
}

$requiredFiles = @(
    'SKILL.md',
    'agents/openai.yaml',
    'references/questioning-framework.md',
    'references/project-association.md',
    'references/final-output-template.md',
    'tests/test-cases.md',
    'tests/behavior-contract.json',
    'tests/latest-forward-test-results.json',
    'tests/trusted-tools.json',
    'tests/release-checklist.md',
    'scripts/build-safe-file-manifest.py',
    'scripts/run-pinned-quick-validate.py',
    'scripts/validate-behavior-contract.ps1',
    'scripts/validate-forward-test-results.ps1',
    'scripts/validate-release.ps1'
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $skillRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-ValidationError "Missing required file: $relativePath"
    }
}

$activeFiles = Get-ChildItem -LiteralPath $skillRoot -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]backups[\\/]' -and
    $_.Extension -in @('.md', '.yaml', '.ps1', '.py', '.json')
}

foreach ($file in $activeFiles) {
    try {
        $content = $strictUtf8.GetString([System.IO.File]::ReadAllBytes($file.FullName))
        if ($content.Contains([char]0xFFFD)) {
            Add-ValidationError "Unicode replacement character found: $($file.FullName)"
        }
    }
    catch {
        Add-ValidationError "File is not strict UTF-8: $($file.FullName)"
    }
}

try {
    [void]$strictUtf8.GetString([byte[]](0xE4, 0xB8))
    Add-ValidationError 'Strict UTF-8 decoder self-test failed'
}
catch [System.Text.DecoderFallbackException] {
    # Expected: malformed UTF-8 must be rejected.
}

$skillPath = Join-Path $skillRoot 'SKILL.md'
$skillText = Get-Content -LiteralPath $skillPath -Encoding UTF8 -Raw
if ($skillText -notmatch '(?s)^---\s*\r?\nname:\s*requirement-clarifier\s*\r?\ndescription:\s*.+?\r?\n---') {
    Add-ValidationError 'SKILL.md frontmatter is invalid'
}

$yamlPath = Join-Path $skillRoot 'agents/openai.yaml'
$yamlText = Get-Content -LiteralPath $yamlPath -Encoding UTF8 -Raw
if (-not $yamlText.Contains('$requirement-clarifier')) {
    Add-ValidationError 'openai.yaml default_prompt must mention $requirement-clarifier'
}
if ($yamlText -match '\u6700\u591A\u63D0\u51FA\s*3\s*\u81F3\s*5') {
    Add-ValidationError 'openai.yaml contains an ambiguous 3-to-5 maximum'
}

$requiredRulePatterns = @(
    '\u5FEB\u901F\u6A21\u5F0F\u6BCF\u8F6E\u6700\u591A\s*3\s*\u4E2A',
    'Codex\s*\u539F\u578B\u63D0\u793A\u8BCD.*\u540E\u7EED\u8F93\u51FA\u9009\u62E9',
    '\u4EC5\u5728\u65B0\u589E\u9875\u9762.*\u4E0D\u5355\u72EC\u6784\u6210\s*P0',
    'G\u3001R\u3001C\u3001I\u3001AC.*\u53EF\u6838\u9A8C\u7684\u5173\u8054',
    '\u4EA7\u54C1\u7ECF\u7406\u80FD\u529B\u590D\u76D8',
    '\u53EA\u8981\s*Codex\s*\u539F\u578B\u63D0\u793A\u8BCD.*\u4E0D\u9644\u52A0\u590D\u76D8',
    '\u9879\u76EE\u5173\u8054\u65B9\u5F0F.*\u4E0D\u662F\s*P0',
    '\u4E0D\u5173\u8054\u9879\u76EE.*\u4E0D\u5F97.*\u5168\u65B0\u9700\u6C42',
    '\u672A\u9009\u62E9\u65F6.*\u4E24\u9009\u4E00',
    '\u4E24\u8F6E\u540E\u4ECD\u5B58\u5728\s*P0',
    '\u8BC4\u5BA1\u4E0E\u8BCA\u65AD',
    '\u4EA4\u4ED8\u8F7D\u4F53\u8303\u56F4',
    '\u51B3\u7B56\u6743',
    '\u654F\u611F\u4FE1\u606F\u95E8\u7981',
    '\u9A8C\u8BC1\u5F3A\u5EA6\u5FC5\u987B\u4E0E\u98CE\u9669\u5339\u914D',
    'build-safe-file-manifest\.py',
    '\u7528\u6237\u81EA\u6211\u58F0\u660E\u4E0D\u6784\u6210',
    'Mock\s*\u6216\u6C99\u7BB1',
    '\u5DE5\u4F5C\u533A\s*dirty/clean',
    '\u6B63\u5F0F\u8F93\u51FA\u524D\u91CD\u65B0\u68C0\u67E5',
    '\u6B63\u5F0F\u65B9\u6848\u540E\u7684\u540E\u7EED\u8F93\u51FA\u9009\u62E9',
    '\u4E24\u9879\u90FD\u751F\u6210',
    '\u9009\u62E9\u524D\u4E0D\u5F97\u81EA\u52A8\u9644\u52A0\u63D0\u793A\u8BCD\u6216\u590D\u76D8'
)
foreach ($pattern in $requiredRulePatterns) {
    if ($skillText -notmatch $pattern) {
        Add-ValidationError "SKILL.md is missing consistency rule matching: $pattern"
    }
}

$testPath = Join-Path $skillRoot 'tests/test-cases.md'
$testText = Get-Content -LiteralPath $testPath -Encoding UTF8 -Raw
$testIds = [regex]::Matches($testText, 'TC-\d+') | ForEach-Object { $_.Value } | Sort-Object -Unique
$headingIds = [regex]::Matches($testText, '^##\s+(TC-\d+)\s+', [System.Text.RegularExpressions.RegexOptions]::Multiline) | ForEach-Object { $_.Groups[1].Value }
$duplicates = $headingIds | Group-Object | Where-Object Count -gt 1
foreach ($duplicate in $duplicates) {
    Add-ValidationError "Duplicate test heading: $($duplicate.Name)"
}
$requiredTests = 1..38 | ForEach-Object { 'TC-{0:D2}' -f $_ }
foreach ($requiredTest in $requiredTests) {
    if ($requiredTest -notin $headingIds) {
        Add-ValidationError "Missing regression test: $requiredTest"
    }
}

$markdownFiles = $activeFiles | Where-Object Extension -eq '.md'
foreach ($file in $markdownFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw
    foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)')) {
        $target = $match.Groups[1].Value
        if ($target -match '^(https?://|mailto:)') {
            continue
        }
        $resolvedTarget = Join-Path $file.DirectoryName $target
        if (-not (Test-Path -LiteralPath $resolvedTarget)) {
            Add-ValidationError "Broken active-document link: $($file.FullName) -> $target"
        }
    }
}

if ($validationErrors.Count -gt 0) {
    $validationErrors | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output "VALIDATION_OK files=$($activeFiles.Count) tests=$($headingIds.Count) behavior_contract=present"
