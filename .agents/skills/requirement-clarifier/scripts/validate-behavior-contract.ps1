$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$contractPath = Join-Path $skillRoot 'tests/behavior-contract.json'
$testCasesPath = Join-Path $skillRoot 'tests/test-cases.md'
$validationErrors = New-Object 'System.Collections.Generic.List[string]'

function Add-ValidationError {
    param([string]$Message)
    $script:validationErrors.Add($Message)
}

try {
    $contract = Get-Content -LiteralPath $contractPath -Encoding UTF8 -Raw | ConvertFrom-Json
}
catch {
    Write-Error "Behavior contract is not valid UTF-8 JSON: $($_.Exception.Message)"
    exit 1
}

if ($contract.version -ne 1) {
    Add-ValidationError 'Behavior contract version must be 1'
}

$cases = @($contract.cases)
if ($cases.Count -eq 0) {
    Add-ValidationError 'Behavior contract must contain at least one case'
}

$requiredIds = 1..12 | ForEach-Object { 'BC-{0:D2}' -f $_ }
$requiredTags = @(
    'quick-escalation',
    'non-ui-carrier',
    'diagnostic-delivery',
    'authority-conflict',
    'sensitive-project-scan',
    'risk-based-demo',
    'association-roundtrip',
    'decision-versioning',
    'explicit-project-consent',
    'evidence-drift',
    'severity-first-mode',
    'post-delivery-choice'
)
$allowedBehaviorCodes = @(
    'append_pm_retro',
    'ask_for_page_scope',
    'ask_more_than_two_attached_business_p0',
    'avoid_page_dependency',
    'auto_generate_prompt_before_choice',
    'build_safe_file_manifest',
    'claim_complete_with_p0',
    'claim_stable_baseline_without_recheck',
    'classify_high_risk',
    'default_to_mock_or_sandbox',
    'defer_project_read_until_choice',
    'deliver_findings_impact_evidence_recommendations',
    'downgrade_p0_to_fit_round_limit',
    'force_deep_mode_for_severe_impact',
    'generate_direct_implementation_plan',
    'generate_full_prd',
    'hide_decision_change',
    'hide_evidence_drift',
    'implement_with_unresolved_p0',
    'increment_decision_version',
    'infer_read_consent_from_project_mention',
    'invent_management_page',
    'keep_diagnostic_scope',
    'offer_project_association_choice',
    'offer_post_delivery_output_choice',
    'override_formal_rule_without_authority',
    'perform_real_external_side_effect',
    'preserve_unresolved_p0',
    'read_blocked_or_unlisted_file',
    'read_only_manifest_allowed_files',
    'read_or_echo_credentials',
    'recheck_evidence_before_final',
    'record_authority_gap',
    'record_worktree_state_and_file_hashes',
    'require_audit_rollback_and_authorization',
    'require_verifiable_authority_evidence',
    'retain_stale_trace_links',
    'scan_project_before_choice',
    'show_overridden_decision_and_impacted_ids',
    'treat_irreversible_delete_as_low_risk',
    'treat_project_mention_as_no_consent',
    'upgrade_to_standard_or_blocked_draft',
    'use_api_as_delivery_carrier',
    'use_standard_mode_due_to_single_role',
    'wait_for_user_optional_output_choice'
)
$allowedProjectAccess = @('none', 'after-consent', 'safe-readonly')
$allowedMutation = @('forbidden', 'explicit-only')
$testCasesText = Get-Content -LiteralPath $testCasesPath -Encoding UTF8 -Raw

$caseIds = @($cases | ForEach-Object { $_.id })
$duplicates = $caseIds | Group-Object | Where-Object Count -gt 1
foreach ($duplicate in $duplicates) {
    Add-ValidationError "Duplicate behavior case id: $($duplicate.Name)"
}

$testCaseReferences = @($cases | ForEach-Object { $_.test_case })
$duplicateTestCaseReferences = $testCaseReferences | Group-Object | Where-Object Count -gt 1
foreach ($duplicate in $duplicateTestCaseReferences) {
    Add-ValidationError "Duplicate behavior test_case mapping: $($duplicate.Name)"
}

foreach ($requiredId in $requiredIds) {
    if ($requiredId -notin $caseIds) {
        Add-ValidationError "Missing behavior case: $requiredId"
    }
}

foreach ($case in $cases) {
    if ($case.id -notmatch '^BC-\d{2}$') {
        Add-ValidationError "Invalid behavior case id: $($case.id)"
    }
    if ([string]::IsNullOrWhiteSpace($case.prompt)) {
        Add-ValidationError "Behavior case $($case.id) has no prompt"
    }
    if (@($case.expected_behaviors).Count -lt 2) {
        Add-ValidationError "Behavior case $($case.id) needs at least two expected behaviors"
    }
    if (@($case.forbidden_behaviors).Count -lt 1) {
        Add-ValidationError "Behavior case $($case.id) needs at least one forbidden behavior"
    }
    foreach ($behaviorCode in @($case.expected_behaviors) + @($case.forbidden_behaviors)) {
        if ($behaviorCode -notin $allowedBehaviorCodes) {
            Add-ValidationError "Behavior case $($case.id) uses unknown behavior code: $behaviorCode"
        }
    }
    $overlap = @($case.expected_behaviors) | Where-Object { $_ -in @($case.forbidden_behaviors) }
    if ($overlap.Count -gt 0) {
        Add-ValidationError "Behavior case $($case.id) has expected/forbidden overlap: $($overlap -join ', ')"
    }
    if ($case.project_access -notin $allowedProjectAccess) {
        Add-ValidationError "Behavior case $($case.id) has invalid project_access"
    }
    if ($case.mutation -notin $allowedMutation) {
        Add-ValidationError "Behavior case $($case.id) has invalid mutation"
    }
    if ($case.max_business_questions_per_round -lt 0 -or $case.max_business_questions_per_round -gt 5) {
        Add-ValidationError "Behavior case $($case.id) has invalid question limit"
    }
    if ([string]::IsNullOrWhiteSpace($case.test_case) -or $testCasesText -notmatch "(?m)^##\s+$([regex]::Escape($case.test_case))\s+") {
        Add-ValidationError "Behavior case $($case.id) references missing test case: $($case.test_case)"
    }
}

$allTags = @($cases | ForEach-Object { @($_.tags) } | Sort-Object -Unique)
foreach ($requiredTag in $requiredTags) {
    if ($requiredTag -notin $allTags) {
        Add-ValidationError "Missing behavior coverage tag: $requiredTag"
    }
}

if ($validationErrors.Count -gt 0) {
    $validationErrors | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output "BEHAVIOR_CONTRACT_OK cases=$($cases.Count) tags=$($allTags.Count)"
