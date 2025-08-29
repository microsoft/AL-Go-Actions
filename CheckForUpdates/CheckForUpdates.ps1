Param(
    [Parameter(HelpMessage = "The GitHub actor running the action", Mandatory = $false)]
    [string] $actor,
    [Parameter(HelpMessage = "Base64 encoded GhTokenWorkflow secret", Mandatory = $false)]
    [string] $token,
    [Parameter(HelpMessage = "URL of the template repository (default is the template repository used to create the repository)", Mandatory = $false)]
    [string] $templateUrl = "",
    [Parameter(HelpMessage = "Set this input to true in order to download latest version of the template repository (else it will reuse the SHA from last update)", Mandatory = $true)]
    [bool] $downloadLatest,
    [Parameter(HelpMessage = "Set this input to Y in order to update AL-Go System Files if needed", Mandatory = $false)]
    [string] $update = 'N',
    [Parameter(HelpMessage = "Set the branch to update", Mandatory = $false)]
    [string] $updateBranch,
    [Parameter(HelpMessage = "Direct Commit?", Mandatory = $false)]
    [bool] $directCommit
)

. (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\TelemetryHelper.psm1' -Resolve)
. (Join-Path -Path $PSScriptRoot -ChildPath "yamlclass.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "CheckForUpdates.HelperFunctions.ps1")

# ContainerHelper is used for determining project folders and dependencies
DownloadAndImportBcContainerHelper

if (-not $templateUrl.Contains('@')) {
    $templateUrl += "@main"
}
if ($templateUrl -notlike "https://*") {
    $templateUrl = "https://github.com/$templateUrl"
}
# Remove www part (if exists)
$templateUrl = $templateUrl -replace "^(https:\/\/)(www\.)(.*)$", '$1$3'

# TemplateUrl is now always a full url + @ and a branch name

if ($update -eq 'Y') {
    if (-not $token) {
        throw "The GhTokenWorkflow secret is needed. Read https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md for more information."
    }
}

if ($token) {
    # token comes from a secret, base 64 encoded
    $token = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($token))
}

# CheckForUpdates will read all AL-Go System files from the Template repository and compare them to the ones in the current repository
# CheckForUpdates will apply changes to the AL-Go System files based on AL-Go repo settings, such as "runs-on" etc.
# if $update is set to Y, CheckForUpdates will also update the AL-Go System files in the current repository using a PR or a direct commit (if $directCommit is set to true)
# if $update is set to N, CheckForUpdates will only check for updates and output a warning if there are updates available
# if $downloadLatest is set to true, CheckForUpdates will download the latest version of the template repository, else it will use the templateSha setting in the .github/AL-Go-Settings file

# Get Repo settings as a hashtable (do NOT read any specific project settings, nor any specific workflow, user or branch settings)
$repoSettings = ReadSettings -buildMode '' -project '' -workflowName '' -userName '' -branchName '' | ConvertTo-HashTable -recurse
$templateSha = $repoSettings.templateSha
$unusedALGoSystemFiles = $repoSettings.unusedALGoSystemFiles
$includeBuildPP = $repoSettings.type -eq 'PTE' -and $repoSettings.powerPlatformSolutionFolder -ne ''
if (!$includeBuildPP) {
    # Remove PowerPlatform workflows if no PowerPlatformSolution exists
    $unusedALGoSystemFiles += @('_BuildPowerPlatformSolution.yaml','PushPowerPlatformChanges.yaml','PullPowerPlatformChanges.yaml')
}

# If templateUrl has changed, download latest version of the template repository (ignore templateSha)
if ($repoSettings.templateUrl -ne $templateUrl -or $templateSha -eq '') {
    $downloadLatest = $true
}

$originalTemplateFolder = $null
$templateFolder = DownloadTemplateRepository -token $token -templateUrl $templateUrl -templateSha ([ref]$templateSha) -downloadLatest $downloadLatest
Write-Host "Template Folder: $templateFolder"

$templateBranch = $templateUrl.Split('@')[1]
$templateOwner = $templateUrl.Split('/')[3]
$templateInfo = "$templateOwner/$($templateUrl.Split('/')[4])"

$isDirectALGo = IsDirectALGo -templateUrl $templateUrl
if (-not $isDirectALGo) {
    $templateRepoSettingsFile = Join-Path $templateFolder "*/$RepoSettingsFile"
    if (Test-Path -Path $templateRepoSettingsFile -PathType Leaf) {
        $templateRepoSettings = Get-Content $templateRepoSettingsFile -Encoding UTF8 | ConvertFrom-Json | ConvertTo-HashTable -Recurse
        if ($templateRepoSettings.Keys -contains "templateUrl" -and $templateRepoSettings.templateUrl -ne $templateUrl) {
            # The template repository is a url to another AL-Go repository (a custom template repository)
            Trace-Information -Message "Using custom AL-Go template repository"

            # TemplateUrl and TemplateSha from .github/AL-Go-Settings.json in the custom template repository points to the "original" template repository
            # Copy files and folders from the custom template repository, but grab the unmodified file from the "original" template repository if it exists and apply customizations
            # Copy .github/AL-Go-Settings.json to .github/templateRepoSettings.doNotEdit.json (will be read before .github/AL-Go-Settings.json in the final repo)
            # Copy .AL-Go/settings.json to .github/templateProjectSettings.doNotEdit.json (will be read before .AL-Go/settings.json in the final repo)

            Write-Host "Custom AL-Go template repository detected, downloading the 'original' template repository"
            $originalTemplateUrl = $templateRepoSettings.templateUrl
            if ($templateRepoSettings.Keys -contains "templateSha") {
                $originalTemplateSha = $templateRepoSettings.templateSha
            }
            else {
                $originalTemplateSha = ""
            }

            # Download the "original" template repository - use downloadLatest if no TemplateSha is specified in the custom template repository
            $originalTemplateFolder = DownloadTemplateRepository -token $token -templateUrl $originalTemplateUrl -templateSha ([ref]$originalTemplateSha) -downloadLatest ($originalTemplateSha -eq '')
            Write-Host "Original Template Folder: $originalTemplateFolder"

            # Set TemplateBranch and TemplateOwner
            # Keep TemplateUrl and TemplateSha pointing to the custom template repository
            $templateBranch = $originalTemplateUrl.Split('@')[1]
            $templateOwner = $originalTemplateUrl.Split('/')[3]

            # If the custom template contains unusedALGoSystemFiles, we need to remove them from the current repository
            if ($templateRepoSettings.ContainsKey('unusedALGoSystemFiles')) {
                $unusedALGoSystemFiles += $templateRepoSettings.unusedALGoSystemFiles
            }
        }
    }
}

# CheckFiles is an array of hashtables with the following properties:
# dstPath: The path to the file in the current repository
# srcPath: The path to the file in the template repository
# pattern: The pattern to use when searching for files in the template repository
# type: The type of file (script, workflow, releasenotes)
# The files currently checked are:
# - All files in .github/workflows
# - All files in .github that ends with .copy.md
# - All PowerShell scripts in .AL-Go folders (all projects)
$checkfiles = @(
    @{ 'dstPath' = (Join-Path '.github' 'workflows'); 'dstName' = ''; 'srcPath' = (Join-Path '.github' 'workflows'); 'pattern' = '*'; 'type' = 'workflow' },
    @{ 'dstPath' = '.github'; 'dstName' = ''; 'srcPath' = '.github'; 'pattern' = '*.copy.md'; 'type' = 'releasenotes' }
    @{ 'dstPath' = '.github'; 'dstName' = ''; 'srcPath' = '.github'; 'pattern' = '*.ps1'; 'type' = 'script' }
    @{ 'dstPath' = '.github'; 'dstName' = ''; 'srcPath' = '.github'; 'pattern' = 'AL-Go-Settings.json'; 'type' = 'settings' },
    @{ 'dstPath' = '.github'; 'dstName' = ''; 'srcPath' = '.github'; 'pattern' = '*.settings.json'; 'type' = 'settings' }
)

if ($originalTemplateFolder) {
    $checkfiles += @(
        @{ 'dstPath' = ([system.IO.Path]::GetDirectoryName($CustomTemplateRepoSettingsFile)); 'dstName' = ([system.IO.Path]::GetFileName($CustomTemplateRepoSettingsFile)); 'SrcPath' = ([system.IO.Path]::GetDirectoryName($RepoSettingsFile)); 'pattern' = ([system.IO.Path]::GetFileName($RepoSettingsFile)); 'type' = 'template repo settings' }
        @{ 'dstPath' = ([system.IO.Path]::GetDirectoryName($CustomTemplateProjectSettingsFile)); 'dstName' = ([system.IO.Path]::GetFileName($CustomTemplateProjectSettingsFile)); 'SrcPath' = ([system.IO.Path]::GetDirectoryName($ALGoSettingsFile)); 'pattern' = ([system.IO.Path]::GetFileName($ALGoSettingsFile)); ; 'type' = 'template project settings' }
    )
}

# Get the list of projects in the current repository
$baseFolder = $ENV:GITHUB_WORKSPACE
$projects = @(GetProjectsFromRepository -baseFolder $baseFolder -projectsFromSettings $repoSettings.projects)
Write-Host "Projects found: $($projects.Count)"
foreach($project in $projects) {
    Write-Host "- $project"
    $checkfiles += @(
        @{ 'dstPath' = Join-Path $project '.AL-Go'; 'dstName' = ''; 'srcPath' = '.AL-Go'; 'pattern' = '*.ps1'; 'type' = 'script' },
        @{ 'dstPath' = Join-Path $project '.AL-Go'; 'dstName' = ''; 'srcPath' = '.AL-Go'; 'pattern' = 'settings.json'; 'type' = 'settings' }
    )
}

# $updateFiles will hold an array of files, which needs to be updated
$updateFiles = @()
# $removeFiles will hold an array of files, which needs to be removed
$removeFiles = @()

# Dependency depth determines how many build jobs we need to run sequentially
# Every build job might spin up multiple jobs in parallel to build the projects without unresolved deependencies
$depth = 1
if ($projects.Count -gt 1) {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "..\DetermineProjectsToBuild\DetermineProjectsToBuild.psm1" -Resolve) -DisableNameChecking
    $allProjects, $modifiedProjects, $projectsToBuild, $projectDependencies, $buildOrder = Get-ProjectsToBuild -baseFolder $baseFolder -buildAllProjects $true -maxBuildDepth 100
    $depth = $buildOrder.Count
    Write-Host "Calculated dependency depth to be $depth"
}

# Loop through all folders in CheckFiles and check if there are any files that needs to be updated
foreach($checkfile in $checkfiles) {
    Write-Host "Checking $($checkfile.srcPath)/$($checkfile.pattern)"
    $type = $checkfile.type
    $srcPath = $checkfile.srcPath
    $dstPath = $checkfile.dstPath
    $dstFolder = Join-Path $baseFolder $dstPath
    $srcFolder = GetSrcFolder -repoType $repoSettings.type -templateUrl $templateUrl -templateFolder $templateFolder -srcPath $srcPath
    $originalSrcFolder = $null
    if ($originalTemplateFolder -and $type -notlike 'template*settings') {
        # Get Original source folder except for template settings - these are applied from the custom template repository
        $originalSrcFolder = GetSrcFolder -repoType $repoSettings.type -templateUrl $originalTemplateUrl -templateFolder $originalTemplateFolder -srcPath $srcPath
    }
    if ($srcFolder) {
        Push-Location -Path $srcFolder
        try {
            # Remove unused AL-Go system files
            $unusedALGoSystemFiles | ForEach-Object {
                if (Test-Path -Path (Join-Path $dstFolder $_) -PathType Leaf) {
                    Write-Host "Remove unused AL-Go system file: $_"
                    $removeFiles += @(Join-Path $dstPath $_)
                }
            }

            # Loop through all files in the template repository matching the pattern
            Get-ChildItem -Path $srcFolder -Filter $checkfile.pattern | ForEach-Object {
                # Read the template file and modify it based on the settings
                # Compare the modified file with the file in the current repository
                if ($checkfile.dstName) {
                    $filename = $checkfile.dstName
                }
                else {
                    $filename = $_.Name
                }
                Write-Host "- $filename"
                $dstFile = Join-Path $dstFolder $filename
                $srcFile = $_.FullName
                $originalSrcFile = $srcFile
                $isFileDirectALGo = $isDirectALGo
                Write-Host "SrcFolder: $srcFolder"
                if ($originalSrcFolder) {
                    # if SrcFile is a custom template repository, we need to find the file in the "original" template repository
                    $fname = Join-Path $originalSrcFolder (Resolve-Path $srcFile -Relative)
                    if (Test-Path -Path $fname -PathType Leaf) {
                        Write-Host "File is available in the 'original' template repository"
                        $originalSrcFile = $fname
                        $isFileDirectALGo = IsDirectALGo -templateUrl $originalTemplateUrl
                    }
                }
                $dstFileExists = Test-Path -Path $dstFile -PathType Leaf
                if ($unusedALGoSystemFiles -contains $fileName) {
                    # File is not used by AL-Go, remove it if it exists
                    # do not add it to $updateFiles if it does not exist
                    if ($dstFileExists) {
                        Write-Host "Removing $type ($(Join-Path $dstPath $filename)) as it is marked as unused."
                        $removeFiles += @(Join-Path $dstPath $filename)
                    }
                    return
                }
                switch ($type) {
                    "workflow" {
                        # For workflow files, we might need to modify the file based on the settings
                        $srcContent = GetWorkflowContentWithChangesFromSettings -srcFile $originalsrcFile -repoSettings $repoSettings -depth $depth -includeBuildPP $includeBuildPP
                     }
                     "settings" {
                        # For settings files, we need to modify the file based on the settings
                        $srcContent = GetModifiedSettingsContent -srcSettingsFile $originalSrcFile -dstSettingsFile $dstFile
                     }
                    Default {
                        # For non-workflow files, just read the file content
                        $srcContent = Get-ContentLF -Path $originalSrcFile
                    }
                }
                # Replace static placeholders
                $srcContent = $srcContent.Replace('{TEMPLATEURL}', $templateUrl)

                if ($isFileDirectALGo) {
                    # If we are using direct AL-Go repo, we need to change the owner to the templateOwner, the repo names to AL-Go and AL-Go/Actions and the branch to templateBranch
                    ReplaceOwnerRepoAndBranch -srcContent ([ref]$srcContent) -templateOwner $templateOwner -templateBranch $templateBranch
                }

                if ($type -eq 'workflow' -and $originalSrcFile -ne $srcFile) {
                    # Apply customizations from custom template repository
                    Write-Host "Apply customizations from custom template repository, file: $srcFile"
                    [Yaml]::ApplyTemplateCustomizations([ref] $srcContent, $srcFile)
                }

                if ($dstFileExists) {
                    if ($type -eq 'workflow') {
                        Write-Host "Apply customizations from current repository, file: $dstFile"
                        [Yaml]::ApplyFinalCustomizations([ref] $srcContent, $dstFile)
                    }

                    # file exists, compare and add to $updateFiles if different
                    $dstContent = Get-ContentLF -Path $dstFile
                    if ($dstContent -cne $srcContent) {
                        Write-Host "Updated $type ($(Join-Path $dstPath $filename)) available"
                        $updateFiles += @{ "DstFile" = Join-Path $dstPath $filename; "content" = $srcContent }
                    }
                    else {
                        Write-Host "No changes in $type ($(Join-Path $dstPath $filename))"
                    }
                }
                else {
                    # new file, add to $updateFiles
                    Write-Host "New $type ($(Join-Path $dstPath $filename)) available"
                    $updateFiles += @{ "DstFile" = Join-Path $dstPath $filename; "content" = $srcContent }
                }
            }
        }
        finally {
            Pop-Location
        }
    }
}
$removeFiles = @($removeFiles | Select-Object -Unique)

if ($update -ne 'Y') {
    # $update not set, just issue a warning in the CI/CD workflow that updates are available
    if (($updateFiles) -or ($removeFiles)) {
        if ($updateFiles) {
            Write-Host "Updated files:"
            $updateFiles | ForEach-Object { Write-Host "- $($_.DstFile)" }

        }
        if ($removeFiles) {
            Write-Host "Removed files:"
            $removeFiles | ForEach-Object { Write-Host "- $_" }
        }
        OutputWarning -message "There are updates for your AL-Go system, run 'Update AL-Go System Files' workflow to download the latest version of AL-Go."
    }
    else {
        OutputNotice -message "No updates available for AL-Go for GitHub."
    }
}
else {
    # $update set, update the files
    try {
        # If a pull request already exists with the same REF, then exit
        $branchSHA = RunAndCheck git rev-list -n 1 $updateBranch '--'
        $commitMessage = "[$($updateBranch)@$($branchSHA.SubString(0,7))] Update AL-Go System Files from $templateInfo - $($templateSha.SubString(0,7))"

        # Get Token with permissions to modify workflows in this repository
        $repoWriteToken = GetAccessToken -token $token -permissions @{"actions"="read";"contents"="write";"pull_requests"="write";"workflows"="write"}
        $env:GH_TOKEN = $repoWriteToken

        $existingPullRequest = (gh api --paginate "/repos/$env:GITHUB_REPOSITORY/pulls?base=$updateBranch" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" | ConvertFrom-Json) | Where-Object { $_.title -eq $commitMessage } | Select-Object -First 1
        if ($existingPullRequest) {
            OutputWarning "Pull request already exists for $($commitMessage): $($existingPullRequest.html_url)."
            exit
        }

        # If $directCommit, then changes are made directly to the default branch
        $serverUrl, $branch = CloneIntoNewFolder -actor $actor -token $repoWriteToken -updateBranch $updateBranch -DirectCommit $directCommit -newBranchPrefix 'update-al-go-system-files'

        invoke-git status

        # Update the files
        # Calculate the release notes, while updating
        $releaseNotes = ""
        $updateFiles | ForEach-Object {
            # Create the destination folder if it doesn't exist
            $path = [System.IO.Path]::GetDirectoryName($_.DstFile)
            if (-not (Test-Path -path $path -PathType Container)) {
                New-Item -Path $path -ItemType Directory | Out-Null
            }
            if (([System.IO.Path]::GetFileName($_.DstFile) -eq "RELEASENOTES.copy.md") -and (Test-Path $_.DstFile)) {
                # Read the release notes of the version currently installed
                $oldReleaseNotes = Get-ContentLF -Path $_.DstFile
                # Get the release notes of the new version (for the PR body)
                $releaseNotes = $_.Content
                # The first line with ## vX.Y, this is the latest shipped version already installed
                $version = $oldReleaseNotes.Split("`n") | Where-Object { $_ -like '## v*.*' } | Select-Object -First 1
                if ($version) {
                    # Only use the release notes up to the version already installed
                    $index = $releaseNotes.IndexOf("`n$version`n")
                    if ($index -ge 0) {
                        $releaseNotes = $releaseNotes.Substring(0,$index)
                    }
                }
            }
            Write-Host "Update $($_.DstFile)"
            $_.Content | Set-ContentLF -Path $_.DstFile
        }
        if ($releaseNotes -eq "") {
            $releaseNotes = "No release notes available!"
        }
        $removeFiles | ForEach-Object {
            Write-Host "Remove $_"
            Remove-Item (Join-Path (Get-Location).Path $_) -Force
        }

        # Update the templateUrl and templateSha in the repo settings file
        UpdateSettingsFile -settingsFile (Join-Path ".github" "AL-Go-Settings.json") -updateSettings @{ "templateUrl" = $templateUrl; "templateSha" = $templateSha }

        Write-Host "ReleaseNotes:"
        Write-Host $releaseNotes

        if (!(CommitFromNewFolder -serverUrl $serverUrl -commitMessage $commitMessage -branch $branch -body $releaseNotes -headBranch $updateBranch)) {
            OutputNotice -message "No updates available for AL-Go for GitHub."
        }
    }
    catch {
        if ($directCommit) {
            throw "Failed to update AL-Go System Files. Make sure that the personal access token, defined in the secret called GhTokenWorkflow, is not expired and it has permission to update workflows. Read https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md for more information. (Error was $($_.Exception.Message))"
        }
        else {
            throw "Failed to create a pull-request to AL-Go System Files. Make sure that the personal access token, defined in the secret called GhTokenWorkflow, is not expired and it has permission to update workflows. Read https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md for more information. (Error was $($_.Exception.Message))"
        }
    }
}
