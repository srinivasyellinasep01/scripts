
# Load required assembly for URL encoding
Add-Type -AssemblyName System.Web

$LOG_FILE = "validation-log-$(Get-Date -Format 'yyyyMMdd').txt"

function Validate-Migration {
    param (
        [string]$adoOrg,
        [string]$adoTeamProject,
        [string]$adoRepo,
        [string]$githubOrg,
        [string]$githubRepo
    )

    Write-Output "[$(Get-Date)] Validating migration: $githubRepo" | Tee-Object -FilePath $LOG_FILE -Append

    # GitHub repo info
    gh repo view "$githubOrg/$githubRepo" --json createdAt,diskUsage,defaultBranchRef,isPrivate |
        Out-File -FilePath "validation-$githubRepo.json"

    # Get GitHub branches (handle pagination)
    $ghBranches = gh api "/repos/$githubOrg/$githubRepo/branches" --paginate | ConvertFrom-Json
    $ghBranchNames = $ghBranches | ForEach-Object { $_.name }

    # Set up ADO auth
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$env:ADO_PAT"))
    $headers = @{ Authorization = "Basic $base64AuthInfo" }

    # Get ADO branches
    $adoBranchUrl = "https://dev.azure.com/$adoOrg/$adoTeamProject/_apis/git/repositories/$adoRepo/refs?filter=heads/&api-version=7.1"
    $adoBranchResponse = Invoke-RestMethod -Uri $adoBranchUrl -Headers $headers -Method Get
    $adoBranches = $adoBranchResponse.value
    $adoBranchNames = $adoBranches | ForEach-Object { $_.name -replace '^refs/heads/', '' }

    # Compare branch counts
    $ghBranchCount = $ghBranchNames.Count
    $adoBranchCount = $adoBranchNames.Count
    $branchCountStatus = if ($ghBranchCount -eq $adoBranchCount) { "✅ Matching" } else { "❌ Not Matching" }

    Write-Output "[$(Get-Date)] Branch Count: ADO=$adoBranchCount | GitHub=$ghBranchCount | $branchCountStatus" | Tee-Object -FilePath $LOG_FILE -Append

    # Compare branch names
    $missingInGH = $adoBranchNames | Where-Object { $_ -notin $ghBranchNames }
    $missingInADO = $ghBranchNames | Where-Object { $_ -notin $adoBranchNames }

    if ($missingInGH.Count -gt 0) {
        Write-Output "[$(Get-Date)] Branches missing in GitHub: $($missingInGH -join ', ')" | Tee-Object -FilePath $LOG_FILE -Append
    }
    if ($missingInADO.Count -gt 0) {
        Write-Output "[$(Get-Date)] Branches missing in ADO: $($missingInADO -join ', ')" | Tee-Object -FilePath $LOG_FILE -Append
    }

    # Validate commit counts and latest commit IDs
    foreach ($branchName in ($ghBranchNames | Where-Object { $_ -in $adoBranchNames })) {
        # GitHub commit count and latest SHA
        $ghCommitCount = 0
        $ghLatestSha = ""
        $page = 1
        $perPage = 100

        do {
            $encodedGhBranchName = [System.Web.HttpUtility]::UrlEncode($branchName)
            $ghCommits = gh api "/repos/$githubOrg/$githubRepo/commits?sha=$encodedGhBranchName&page=$page&per_page=$perPage" | ConvertFrom-Json
            if ($page -eq 1 -and $ghCommits.Count -gt 0) {
                $ghLatestSha = $ghCommits[0].sha
            }
            $ghCommitCount += $ghCommits.Count
            $page++
        } while ($ghCommits.Count -eq $perPage)

        # ADO commit count and latest SHA
        $adoCommitCount = 0
        $adoLatestSha = ""
        $skip = 0
        $batchSize = 1000

        do {
            $encodedBranchName = [System.Web.HttpUtility]::UrlEncode($branchName)
            $adoUrl = "https://dev.azure.com/$adoOrg/$adoTeamProject/_apis/git/repositories/$adoRepo/commits?`$top=$batchSize&`$skip=$skip&searchCriteria.itemVersion.version=$encodedBranchName&searchCriteria.itemVersion.versionType=branch&api-version=7.1"
            $adoResponse = Invoke-RestMethod -Uri $adoUrl -Headers $headers -Method Get
            $adoBatch = $adoResponse.value
            if ($skip -eq 0 -and $adoBatch.Count -gt 0) {
                $adoLatestSha = $adoBatch[0].commitId
            }
            $adoCommitCount += $adoBatch.Count
            $skip += $batchSize
        } while ($adoBatch.Count -eq $batchSize)

        # Match status
        $countMatch = ($ghCommitCount -eq $adoCommitCount)
        $shaMatch = ($ghLatestSha -eq $adoLatestSha)

        $commitCountStatus = if ($countMatch) { "✅ Matching" } else { "❌ Not Matching" }
        $shaStatus = if ($shaMatch) { "✅ Matching" } else { "❌ Not Matching" }

        # Log results
        Write-Output "[$(Get-Date)] Branch '$branchName': ADO Commits=$adoCommitCount | GitHub Commits=$ghCommitCount | $commitCountStatus" | Tee-Object -FilePath $LOG_FILE -Append
        Write-Output "[$(Get-Date)] Branch '$branchName': ADO SHA=$adoLatestSha | GitHub SHA=$ghLatestSha | $shaStatus" | Tee-Object -FilePath $LOG_FILE -Append
    }


    Write-Output "[$(Get-Date)] Validation complete for $githubRepo" | Tee-Object -FilePath $LOG_FILE -Append
}

function Validate-FromCSV {
    param (
        [string]$csvPath = "repos.csv"
    )

    if (-not (Test-Path $csvPath)) {
        Write-Output "[$(Get-Date)] ERROR: CSV file not found: $csvPath" | Tee-Object -FilePath $LOG_FILE -Append
        return
    }

    $repos = Import-Csv -Path $csvPath

    foreach ($repo in $repos) {
        Write-Output "[$(Get-Date)] Processing: $($repo.repo) -> $($repo.github_repo)" | Tee-Object -FilePath $LOG_FILE -Append
        
        Validate-Migration -adoOrg $repo.org `
                          -adoTeamProject $repo.teamproject `
                          -adoRepo $repo.repo `
                          -githubOrg $repo.github_org `
                          -githubRepo $repo.github_repo
    }

    Write-Output "[$(Get-Date)] All validations from CSV completed" | Tee-Object -FilePath $LOG_FILE -Append
}


# Single repository validation (commented out)
#$ADO_ORG = "contosodevopstest"
#$ADO_PROJECT = "StarReads"
#$ADO_REPO = "StarReads"
#$GITHUB_ORG = "ADO2GH-Migration"
#$GH_REPO = "StarReads"

# Single repository mode (commented out)
#Validate-Migration -adoOrg $ADO_ORG -adoTeamProject $ADO_PROJECT -adoRepo $ADO_REPO -githubOrg $GITHUB_ORG -githubRepo $GH_REPO

# CSV validation mode - validate all migrated repositories
Validate-FromCSV -csvPath "repos.csv"