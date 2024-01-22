Param(
    [Parameter(HelpMessage = "The GitHub actor running the action", Mandatory = $false)]
    [string] $actor,
    [Parameter(HelpMessage = "The GitHub token running the action", Mandatory = $false)]
    [string] $token,
    [Parameter(HelpMessage = "Specifies the parent telemetry scope for the telemetry signal", Mandatory = $false)]
    [string] $parentTelemetryScopeJson = '7b7d',
    [Parameter(HelpMessage = "Project name if the repository is setup for multiple projects", Mandatory = $false)]
    [string] $project = '.',
    [Parameter(HelpMessage = "Direct Download Url of .app or .zip file", Mandatory = $true)]
    [string] $url,
    [Parameter(HelpMessage = "Set the branch to update", Mandatory = $false)]
    [string] $updateBranch,
    [Parameter(HelpMessage = "Direct Commit?", Mandatory = $false)]
    [bool] $directCommit
)

function getfiles {
    Param(
        [string] $url
    )

    $path = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid().ToString()).app"
    Download-File -sourceUrl $url -destinationFile $path
    if (!(Test-Path -Path $path)) {
        throw "could not download the file."
    }

    expandfile -path $path
    Remove-Item $path -Force -ErrorAction SilentlyContinue
}

function expandfile {
    Param(
        [string] $path
    )

    if ([string]::new([char[]](Get-Content $path @byteEncodingParam -TotalCount 2)) -eq "PK") {
        # .zip file
        $destinationPath = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid().ToString())"
        Expand-7zipArchive -path $path -destinationPath $destinationPath

        $directoryInfo = Get-ChildItem $destinationPath | Measure-Object
        if ($directoryInfo.count -eq 0) {
            throw "The file is empty or malformed."
        }

        $appFolders = @()
        if (Test-Path (Join-Path $destinationPath 'app.json')) {
            $appFolders += @($destinationPath)
        }
        Get-ChildItem $destinationPath -Recurse | Where-Object { $_.PSIsContainer -and (Test-Path -Path (Join-Path $_.FullName 'app.json')) } | ForEach-Object {
            if (!($appFolders -contains $_.Parent.FullName)) {
                $appFolders += @($_.FullName)
            }
        }
        $appFolders | ForEach-Object {
            $newFolder = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid().ToString())"
            write-Host "$_ -> $newFolder"
            Move-Item -Path $_ -Destination $newFolder -Force
            Write-Host "done"
            $newFolder
        }
        if (Test-Path $destinationPath) {
            Get-ChildItem $destinationPath -include @("*.zip", "*.app") -Recurse | ForEach-Object {
                expandfile $_.FullName
            }
            Remove-Item -Path $destinationPath -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    elseif ([string]::new([char[]](Get-Content $path @byteEncodingParam -TotalCount 4)) -eq "NAVX") {
        $destinationPath = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid().ToString())"
        Extract-AppFileToFolder -appFilename $path -appFolder $destinationPath -generateAppJson
        $destinationPath
    }
    else {
        throw "The provided url cannot be extracted. The url might be wrong or the file is malformed."
    }
}

$telemetryScope = $null

try {
    . (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)
    $serverUrl, $branch = CloneIntoNewFolder -actor $actor -token $token -updateBranch $updateBranch -DirectCommit $directCommit -newBranchPrefix 'add-existing-app'
    $baseFolder = (Get-Location).path
    DownloadAndImportBcContainerHelper -baseFolder $baseFolder

    import-module (Join-Path -path $PSScriptRoot -ChildPath "..\TelemetryHelper.psm1" -Resolve)
    $telemetryScope = CreateScope -eventId 'DO0070' -parentTelemetryScopeJson $parentTelemetryScopeJson

    $type = "PTE"
    Write-Host "Reading $RepoSettingsFile"
    $settingsJson = Get-Content $RepoSettingsFile -Encoding UTF8 | ConvertFrom-Json
    if ($settingsJson.PSObject.Properties.Name -eq "type") {
        $type = $settingsJson.type
    }

    CheckAndCreateProjectFolder -project $project
    $projectFolder = (Get-Location).path

    $appNames = @()
    getfiles -url $url | ForEach-Object {
        $appFolder = $_
        "?Content_Types?.xml", "MediaIdListing.xml", "navigation.xml", "NavxManifest.xml", "DocComments.xml", "SymbolReference.json" | ForEach-Object {
            Remove-Item (Join-Path $appFolder $_) -Force -ErrorAction SilentlyContinue
        }
        $appJson = Get-Content (Join-Path $appFolder "app.json") -Encoding UTF8 | ConvertFrom-Json
        $appNames += @($appJson.Name)

        $ranges = @()
        if ($appJson.PSObject.Properties.Name -eq "idRanges") {
            $ranges += $appJson.idRanges
        }
        if ($appJson.PSObject.Properties.Name -eq "idRange") {
            $ranges += @($appJson.idRange)
        }

        # Determine whether the app is PTE or AppSource App based on one of the id ranges (the first)
        if ($ranges[0].from -lt 100000 -and $ranges[0].to -lt 100000) {
            $ttype = "PTE"
        }
        else {
            $ttype = "AppSource App"
        }

        if ($appJson.PSObject.Properties.Name -eq "dependencies") {
            foreach($dependency in $appJson.dependencies) {
                if ($dependency.PSObject.Properties.Name -eq "AppId") {
                    $id = $dependency.AppId
                }
                else {
                    $id = $dependency.Id
                }
                if ($testRunnerApps.Contains($id)) {
                    $ttype = "Test App"
                }
            }
        }

        if ($ttype -ne "Test App") {
            foreach($appName in (Get-ChildItem -Path $appFolder -Filter "*.al" -Recurse).FullName) {
                $alContent = (Get-Content -Path $appName -Encoding UTF8) -join "`n"
                if ($alContent -like "*codeunit*subtype*=*test*[test]*") {
                    $ttype = "Test App"
                }
            }
        }

        if ($ttype -ne "Test App" -and $ttype -ne $type) {
            OutputWarning -message "According to settings, repository is for apps of type $type. The app you are adding seams to be of type $ttype"
        }

        $appFolders = Get-ChildItem -Path $appFolder | Where-Object { $_.PSIsContainer -and (Test-Path (Join-Path $_.FullName 'app.json')) }
        if (-not $appFolders) {
            $appFolders = @($appFolder)
            # TODO: What to do about the über app.json - another workspace? another setting?
        }

        $orgfolderName = $appJson.name.Split([System.IO.Path]::getInvalidFileNameChars()) -join ""
        $folderName = GetUniqueFolderName -baseFolder $projectFolder -folderName $orgfolderName
        if ($folderName -ne $orgfolderName) {
            OutputWarning -message "$orgFolderName already exists as a folder in the repo, using $folderName instead"
        }

        Move-Item -Path $appFolder -Destination $projectFolder -Force
        Rename-Item -Path ([System.IO.Path]::GetFileName($appFolder)) -NewName $folderName
        $appFolder = Join-Path $projectFolder $folderName

        Get-ChildItem $appFolder -Filter '*.*' -Recurse | ForEach-Object {
            if ($_.Name.Contains('%20')) {
                Rename-Item -Path $_.FullName -NewName $_.Name.Replace('%20', ' ')
            }
        }

        $appFolders | ForEach-Object {
            # Modify .AL-Go\settings.json
            try {
                $settingsJsonFile = Join-Path $projectFolder $ALGoSettingsFile
                $SettingsJson = Get-Content $settingsJsonFile -Encoding UTF8 | ConvertFrom-Json
                if (@($settingsJson.appFolders) + @($settingsJson.testFolders)) {
                    if ($ttype -eq "Test App") {
                        if ($SettingsJson.testFolders -notcontains $foldername) {
                            $SettingsJson.testFolders += @($folderName)
                        }
                    }
                    else {
                        if ($SettingsJson.appFolders -notcontains $foldername) {
                            $SettingsJson.appFolders += @($folderName)
                        }
                    }
                    $SettingsJson | Set-JsonContentLF -Path $settingsJsonFile
                }
            }
            catch {
                throw "$ALGoSettingsFile is malformed. Error: $($_.Exception.Message)"
            }

            # Modify workspace
            Get-ChildItem -Path $projectFolder -Filter "*.code-workspace" | ForEach-Object {
                try {
                    $workspaceFileName = $_.Name
                    $workspaceFile = $_.FullName
                    $workspace = Get-Content $workspaceFile -Encoding UTF8 | ConvertFrom-Json
                    if (-not ($workspace.folders | Where-Object { $_.Path -eq $foldername })) {
                        $workspace.folders += @(@{ "path" = $foldername })
                    }
                    $workspace | Set-JsonContentLF -Path $workspaceFile
                }
                catch {
                    throw "$workspaceFileName is malformed.$([environment]::Newline) $($_.Exception.Message)"
                }
            }
        }
    }
    Set-Location $baseFolder
    CommitFromNewFolder -serverUrl $serverUrl -commitMessage "Add existing apps ($($appNames -join ', '))" -branch $branch | Out-Null

    TrackTrace -telemetryScope $telemetryScope
}
catch {
    if (Get-Module BcContainerHelper) {
        TrackException -telemetryScope $telemetryScope -errorRecord $_
    }
    throw
}
