Param(
    [Parameter(HelpMessage = "Project folder", Mandatory = $false)]
    [string] $ProjectPath = ""
)

$projectPathCompleted = $null

$baseFolder = $ENV:GITHUB_WORKSPACE
$projectPathCompleted = Join-Path -Path $baseFolder -ChildPath ($ProjectPath + "\app")

Write-Host "::group::Rename All Objects Id"
Write-Host "Script path: $PSScriptRoot"
Write-Host "Project path: $projectPathCompleted"
Write-Host $projectPath
# Rename All Objects Id
$RenameAllObjectsPath = (Join-Path -Path $PSScriptRoot -ChildPath "..\RenumberObjects\renumberObjects.js" -Resolve)
Write-Host "Rename Objects script path: $RenameAllObjectsPath"
Write-Host "Renamed all fields..."
& 'C:\Program Files\nodejs\node.exe' $RenameAllObjectsPath $projectPathCompleted
Write-Host "::endgroup::"