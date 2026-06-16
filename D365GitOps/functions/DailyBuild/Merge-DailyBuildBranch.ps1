<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>

[CmdletBinding()]
param(
	[string]$OrganizationUri = $env:SYSTEM_COLLECTIONURI,
	[string]$Project = $env:SYSTEM_TEAMPROJECTID,
	[string]$RepositoryName = $env:BUILD_REPOSITORY_NAME,
	[string]$RepositoryDirectory = $env:BUILD_SOURCESDIRECTORY,
	[string]$DailyBuildBranch = 'daily-build',
	[ValidateSet('merge', 'squash')]
	[string]$MergeStrategy = 'merge',
	[int]$DefaultPriority = 100,
	[string]$Pat = $env:DEVOPS_PAT,
	[switch]$SkipUnchangedPush
)

# if ($MyInvocation.InvocationName -eq '.') {
#     return
# }

if ($env:SYSTEM_DEBUG -eq 'true') {
	$VerbosePreference = 'Continue'
	Write-Verbose "PWD: $PWD"
	Write-Verbose "OrganizationUri: $OrganizationUri"
	Write-Verbose "Project: $Project"
	Write-Verbose "RepositoryName: $RepositoryName"
	Write-Verbose "DailyBuildBranch: $DailyBuildBranch"
	Write-Verbose "MergeStrategy: $MergeStrategy"
	Write-Verbose "DefaultPriority: $DefaultPriority"
	Write-Verbose "SkipUnchangedPush: $SkipUnchangedPush"

	Get-ChildItem
}

Push-Location -Path $RepositoryDirectory

$gitArgs = @(
	'-c',
	"http.extraheader=AUTHORIZATION: Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("PAT:$Pat")))"
)

function Resolve-PullRequestPriority {
	param(
		[Parameter(Mandatory = $true)]
		$Labels
	)

	$resolved = $DefaultPriority
	foreach ($label in @($Labels | ForEach-Object { $_.name })) {
		if ($label -match '^priority:(\d+)$') {
			$val = [int]$Matches[1]
			if ($val -lt $resolved) { $resolved = $val }
		}
	}
	return $resolved
}

function Invoke-Git {
	param(
		[Parameter(Mandatory = $true)]
		[string[]]$Args
	)

	Write-Verbose "Running git $($Args -join ' ')"
	& git @gitArgs @Args
	if ($LASTEXITCODE -ne 0) {
		throw "git $($Args -join ' ') failed with exit code $LASTEXITCODE."
	}
}

function Get-CommitIdentity {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Ref
	)

	Write-Verbose "Resolving commit identity for $Ref..."
	$identity = & git @gitArgs 'show' '--no-patch' "--format=%an`n%ae" $Ref
	if ($LASTEXITCODE -ne 0) {
		throw "Failed to resolve commit identity for $Ref. Please verify fetch depth."
	}

	$identityLines = @($identity | Where-Object { $_ -ne $null })
	if ($identityLines.Count -lt 2) {
		throw "Commit identity for $Ref is incomplete."
	}

	return @{
		Name  = $identityLines[0]
		Email = $identityLines[1]
	}
}

function Invoke-GitWithCommitIdentity {
	param(
		[Parameter(Mandatory = $true)]
		[hashtable]$Identity,
		[Parameter(Mandatory = $true)]
		[string[]]$Args
	)

	Write-Verbose "Running git $($Args -join ' ') with identity $($Identity.Name) <$($Identity.Email)>"
	& git @gitArgs '-c' "user.name=$($Identity.Name)" '-c' "user.email=$($Identity.Email)" @Args
	if ($LASTEXITCODE -ne 0) {
		throw "git $($Args -join ' ') failed with exit code $LASTEXITCODE."
	}
}

function Get-BuildResultsUrl {
	$collectionUri = if ($env:SYSTEM_COLLECTIONURI) { $env:SYSTEM_COLLECTIONURI } else { $OrganizationUri }
	if ([string]::IsNullOrWhiteSpace($collectionUri)) {
		return ''
	}

	$buildId = $env:BUILD_BUILDID
	if ([string]::IsNullOrWhiteSpace($buildId)) {
		return ''
	}

	$projectName = if ($env:SYSTEM_TEAMPROJECT) { $env:SYSTEM_TEAMPROJECT } else { $Project }
	$baseUri = $collectionUri.TrimEnd('/')
	$queryParts = @{
		"buildId" = $buildId
		'view'    = 'logs'
		"j"       = $env:SYSTEM_JOBID
		"t"       = $env:SYSTEM_TASKINSTANCEID
		"s"       = $env:SYSTEM_STAGEID
	}

	$queryString = ($queryParts.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) -join '&'

	return "$baseUri/$([Uri]::EscapeDataString($projectName))/_build/results?$queryString"
}

function Set-PullRequestStatus {
	param(
		[Parameter(Mandatory = $true)]
		[int]$PullRequestId,
		[Parameter(Mandatory = $true)]
		[int]$IterationId,
		[Parameter(Mandatory = $true)]
		[ValidateSet('succeeded', 'failed', 'pending', 'notSet', 'error')]
		[string]$State,
		[Parameter(Mandatory = $true)]
		[string]$Description
	)

	$authHeader = "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("PAT:$Pat")))"
	$targetUrl = Get-BuildResultsUrl
	$body = @{
		state       = $State
		description = $Description
		iterationId = $IterationId
		context     = @{
			name  = 'daily-build'
			genre = 'daily-build'
		}
		targetUrl   = $targetUrl
	} | ConvertTo-Json
	Write-Verbose "Posting status to PR !$PullRequestId (iteration: $IterationId): $State - $Description"
	$uri = "$OrganizationUri/$([Uri]::EscapeDataString($Project))/_apis/git/repositories/$repositoryId/pullRequests/$PullRequestId/statuses?api-version=7.1"
	try {
		Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json' -Headers @{ Authorization = $authHeader } | Out-Null
	}
 catch {
		Write-Warning "Failed to post status to PR !$PullRequestId : $_"
	}
}

function Get-LatestPullRequestIteration {
	param(
		[Parameter(Mandatory = $true)]
		[int]$PullRequestId
	)

	$authHeader = "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("PAT:$Pat")))"
	$uri = "$OrganizationUri/$([Uri]::EscapeDataString($Project))/_apis/git/repositories/$repositoryId/pullRequests/$PullRequestId/iterations?includeCommits=false&api-version=7.1"
	
	Write-Verbose "Fetching iterations for PR !$PullRequestId..."
	$response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = $authHeader }

	if (-not $response -or -not $response.value -or $response.value.Count -eq 0) {
		throw "No iterations found for PR !$PullRequestId."
	}

	# The API returns iterations in ascending order; the last one is the current iteration.
	Write-Verbose "Found $($response.value.Count) iterations for PR !$PullRequestId. Returning the latest iteration (ID: $($response.value[-1].id))."
	return $response.value[-1]
}

function Resolve-IterationIdForStatus {
	param(
		[Parameter(Mandatory = $true)]
		$PullRequestItem
	)

	if ($PullRequestItem.PSObject.Properties.Name -contains 'Iteration' -and $PullRequestItem.Iteration -and $PullRequestItem.Iteration.Id) {
		return [int]$PullRequestItem.Iteration.Id
	}

	return 1
}

$env:AZURE_DEVOPS_EXT_PAT = $Pat
$azExtensions = az extension list --query '[].name' --output json | ConvertFrom-Json
if ($azExtensions -notcontains 'azure-devops') {
	az extension add --name azure-devops
}
az devops configure --defaults organization=$OrganizationUri project=$Project

Write-Verbose "Fetching active PRs targeting 'main'..."
$prResponse = az repos pr list --repository "$RepositoryName" --target-branch main --status active --query '[?!isDraft]' --output json
$pr = ($prResponse | ConvertFrom-Json)
Write-Verbose "Fetched $($pr.Count) active PRs targeting 'main'."
$pr = $pr | Where-Object {
	if (!$_.labels) { $_.labels = @() }
	$labelNames = @($_.labels | ForEach-Object { $_.name })
	$labelNames -notcontains 'AutoMergeIgnore'
}

$pr = $pr | Sort-Object -Property @(
	@{ Expression = { Resolve-PullRequestPriority $_.labels }; Ascending = $true },
	@{ Expression = { $_.pullRequestId }; Ascending = $true }
)

$repositoryId = (az repos show --repository "$RepositoryName" --query id --output tsv).Trim()

Invoke-Git @('fetch', 'origin', 'main')
Invoke-Git @('checkout', '-B', $DailyBuildBranch, 'origin/main')
$mergeLabelScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ps_modules/D365GitOps/functions/MergeDrivers/Merge-D365LabelFile.ps1'
if (Test-Path -Path $mergeLabelScriptPath) {
	Invoke-Git @('config', 'merge.d365fo-label.driver', "pwsh -File `"$mergeLabelScriptPath`" -Base %O -Ours %A -Theirs %B -MarkerSize %L -FilePath %P")
}
else {
	Write-Verbose -Verbose "Merge label driver script not found at $mergeLabelScriptPath. Skipping merge.d365fo-label.driver configuration."
}
$mergedPRs = @()
$skippedPRs = @()

foreach ($item in $pr) {
	if (-not $item.sourceRefName) {
		Write-Warning "Skipping PR $($item.pullRequestId): missing sourceRefName."
		continue
	}

	if ($item.supportsIterations) {
		$iteration = Get-LatestPullRequestIteration -PullRequestId $item.pullRequestId
		$item | Add-Member -MemberType NoteProperty -Name Iteration -Value $iteration
		if ($item.lastMergeSourceCommit.commitId -ne $item.Iteration.sourceRefCommit.commitId) {
			Write-Warning "Skipping PR $($item.pullRequestId): source branch has new commits since last iteration."
			$skippedPRs += $item
			continue
		}
	}

	$sourceBranch = $item.sourceRefName -replace '^refs/heads/', ''
	$resolvedPriority = Resolve-PullRequestPriority $item.labels
	$sourceIdentity = Get-CommitIdentity "origin/$sourceBranch"
	Write-Host "Merging PR $($item.pullRequestId) from $sourceBranch (priority: $resolvedPriority)"

	try {
		switch ($MergeStrategy) {
			'squash' {
				Invoke-Git @('merge', '--squash', "origin/$sourceBranch")
				Invoke-GitWithCommitIdentity $sourceIdentity @('commit', '-m', "Squash PR !$($item.pullRequestId)")
			}
			default {
				Invoke-GitWithCommitIdentity $sourceIdentity @('merge', '--no-ff', "origin/$sourceBranch", '-m', "Merge PR !$($item.pullRequestId)")
			}
		}
		$mergedPRs += $item
	}
 catch {
		Write-Warning "Merge failed for PR $($item.pullRequestId) ($sourceBranch). Skipping."
		& git merge --abort | Out-Null
		& git reset --hard HEAD | Out-Null
		$skippedPRs += $item
		continue
	}
}

$shouldPush = $true
if ($SkipUnchangedPush) {
	# Silently try to fetch the remote daily-build branch (may not exist yet)
	& git @gitArgs fetch origin $DailyBuildBranch 2>$null | Out-Null
	# Check if the remote ref exists
	& git rev-parse --verify "origin/$DailyBuildBranch" 2>$null | Out-Null
	if ($LASTEXITCODE -eq 0) {
		# Compare trees; exit code 0 means no difference
		& git diff --quiet "origin/$DailyBuildBranch" HEAD
		if ($LASTEXITCODE -eq 0) {
			Write-Host "No content changes vs 'origin/$DailyBuildBranch' - skipping push."
			$shouldPush = $false
		}
	}
}

if ($shouldPush) {
	Invoke-Git @('push', '--force', 'origin', $DailyBuildBranch)
}

foreach ($item in $mergedPRs) {
	try {
		$iterationId = Resolve-IterationIdForStatus -PullRequestItem $item
		Set-PullRequestStatus -PullRequestId $item.pullRequestId -IterationId $iterationId -State 'succeeded' -Description "Merged into daily-build (iteration: $iterationId) $($item.lastMergeSourceCommit.commitId)"
	}
 catch {
		Write-Warning "Failed to post status for PR $($item.pullRequestId): $_"
	}
}
foreach ($item in $skippedPRs) {
	try {
		$iterationId = Resolve-IterationIdForStatus -PullRequestItem $item
		Set-PullRequestStatus -PullRequestId $item.pullRequestId -IterationId $iterationId -State 'failed' -Description "Merge conflict - skipped (iteration: $iterationId) $($item.lastMergeSourceCommit.commitId)"
	}
 catch {
		Write-Warning "Failed to post status for PR $($item.pullRequestId): $_"
	}
}

Write-Host ''
Write-Host '=== Daily Build Summary ==='
if ($mergedPRs.Count -gt 0) {
	$mergedList = ($mergedPRs | ForEach-Object { "!$($_.pullRequestId)" }) -join ', '
	Write-Host "Merged:  $mergedList"
}
else {
	Write-Host 'Merged:  (none)'
}
if ($skippedPRs.Count -gt 0) {
	$skippedList = ($skippedPRs | ForEach-Object { "!$($_.pullRequestId) (merge conflict)" }) -join ', '
	Write-Host "Skipped: $skippedList"
}
else {
	Write-Host 'Skipped: (none)'
}
