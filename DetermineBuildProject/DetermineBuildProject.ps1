Param(
    [Parameter(HelpMessage = "The GitHub token running the action", Mandatory = $false)]
    [string] $token,
    [Parameter(HelpMessage = "Compressed JSON string containing the list of projects that should be skipped", Mandatory = $true)]
    [string] $skippedProjectsJson,
    [Parameter(HelpMessage = "Name of the project to build", Mandatory = $true)]
    [string] $project,
    [Parameter(HelpMessage = "Id of the baseline workflow run, from which to download artifacts if build is skipped", Mandatory = $false)]
    [string] $baselineWorkflowRunId
)

. (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)

$settings = $env:Settings | ConvertFrom-Json | ConvertTo-HashTable -recurse
$baseFolder = $ENV:GITHUB_WORKSPACE
$projectPath = Join-Path $baseFolder $project
$buildArtifactFolder = Join-Path $projectPath ".buildartifacts"
$skippedProjects = $skippedProjectsJson | ConvertFrom-Json
$buildIt = $skippedProjects -notcontains $project
if (!$buildIt) {
    # Download the artifacts from the baseline workflow run
    # Set buildIt to true if the download isn't successful
    New-Item $buildArtifactFolder -ItemType Directory | Out-Null
    $buildIt = $true
    foreach($mask in @('Apps','TestApps','Dependencies','PowerPlatformSolution')) {
        $artifact = GetArtifactsFromWorkflowRun -workflowRun $baselineWorkflowRunId -token $token -api_url $env:GITHUB_API_URL -repository $env:GITHUB_REPOSITORY -mask $mask -projects $project
        if ($artifact) {
            Write-Host "Artifact found for mask $mask"
            if ($artifact -is [Array]) {
                throw "Multiple artifacts found with mask $mask for project $project"
            }
            $file = DownloadArtifact -path $buildArtifactFolder -token $token -artifact $artifact
            if ($file) {
                Write-Host "Artifact downloaded for mask $mask"
                $thisArtifactFolder = Join-Path $buildArtifactFolder $mask
                Expand-Archive -Path $file -DestinationPath $thisArtifactFolder -Force
                Remove-Item -Path $file -Force
                $buildIt = $false
            }
        }
    }
    if ($buildIt) {
        # No artifacts available/downloaded - remove the build artifact folder and build the project
        Remove-Item -Path $buildArtifactFolder -Recurse -Force
    }
}

Add-Content -Encoding UTF8 -Path $env:GITHUB_OUTPUT -Value "BuildIt=$buildIt"
Write-Host "BuildIt=$buildIt"
