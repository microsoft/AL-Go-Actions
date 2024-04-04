Param(
    [switch] $local
)

$gitHubHelperPath = Join-Path $PSScriptRoot 'Github-Helper.psm1'
if (Test-Path $gitHubHelperPath) {
    Import-Module $gitHubHelperPath
}

$ErrorActionPreference = "stop"
Set-StrictMode -Version 2.0

$ALGoFolder = ".AL-Go\"
$ALGoSettingsFile = ".AL-Go\settings.json"
$RepoSettingsFile = ".github\AL-Go-Settings.json"
$runningLocal = $local.IsPresent

$runAlPipelineOverrides = @(
    "DockerPull"
    "NewBcContainer"
    "ImportTestToolkitToBcContainer"
    "CompileAppInBcContainer"
    "GetBcContainerAppInfo"
    "PublishBcContainerApp"
    "UnPublishBcContainerApp"
    "InstallBcAppFromAppSource"
    "SignBcContainerApp"
    "ImportTestDataInBcContainer"
    "RunTestsInBcContainer"
    "GetBcContainerAppRuntimePackage"
    "RemoveBcContainer"
)

# Well known AppIds
$systemAppId = "63ca2fa4-4f03-4f2b-a480-172fef340d3f"
$baseAppId = "437dbf0e-84ff-417a-965d-ed2bb9650972"
$applicationAppId = "c1335042-3002-4257-bf8a-75c898ccb1b8"
$permissionsMockAppId = "40860557-a18d-42ad-aecb-22b7dd80dc80"
$testRunnerAppId = "23de40a6-dfe8-4f80-80db-d70f83ce8caf"
$anyAppId = "e7320ebb-08b3-4406-b1ec-b4927d3e280b"
$libraryAssertAppId = "dd0be2ea-f733-4d65-bb34-a28f4624fb14"
$libraryVariableStorageAppId = "5095f467-0a01-4b99-99d1-9ff1237d286f"
$systemApplicationTestLibraryAppId = "9856ae4f-d1a7-46ef-89bb-6ef056398228"
$TestsTestLibrariesAppId = "5d86850b-0d76-4eca-bd7b-951ad998e997"
$performanceToolkitAppId = "75f1590f-55c5-4501-ae63-bada5534e852"

$performanceToolkitApps = @($performanceToolkitAppId)
$testLibrariesApps = @($systemApplicationTestLibraryAppId, $TestsTestLibrariesAppId)
$testFrameworkApps = @($anyAppId, $libraryAssertAppId, $libraryVariableStorageAppId) + $testLibrariesApps
$testRunnerApps = @($permissionsMockAppId, $testRunnerAppId) + $performanceToolkitApps + $testLibrariesApps + $testFrameworkApps

$MicrosoftTelemetryConnectionString = "InstrumentationKey=84bd9223-67d4-4378-8590-9e4a46023be2;IngestionEndpoint=https://westeurope-1.in.applicationinsights.azure.com/"

function invoke-git {
    Param(
        [parameter(mandatory = $true, position = 0)][string] $command,
        [parameter(mandatory = $false, position = 1, ValueFromRemainingArguments = $true)] $remaining
    )

    Write-Host -ForegroundColor Yellow "git $command $remaining"
    git $command $remaining
    if ($lastexitcode) { throw "git $command error" }
}

function invoke-gh {
    Param(
        [parameter(mandatory = $true, position = 0)][string] $command,
        [parameter(mandatory = $false, position = 1, ValueFromRemainingArguments = $true)] $remaining
    )

    Write-Host -ForegroundColor Yellow "gh $command $remaining"
    $ErrorActionPreference = "SilentlyContinue"
    gh $command $remaining
    $ErrorActionPreference = "Stop"
    if ($lastexitcode) { throw "gh $command error" }
}

function ConvertTo-HashTable {
    [CmdletBinding()]
    Param(
        [parameter(ValueFromPipeline)]
        [PSCustomObject] $object
    )
    $ht = @{}
    if ($object) {
        $object.PSObject.Properties | Foreach { $ht[$_.Name] = $_.Value }
    }
    $ht
}

function OutputError {
    Param(
        [string] $message
    )

    if ($runningLocal) {
        throw $message
    }
    else {
        Write-Host "::Error::$message"
        $host.SetShouldExit(1)
    }
}

function OutputWarning {
    Param(
        [string] $message
    )

    if ($runningLocal) {
        Write-Host -ForegroundColor Yellow "WARNING: $message"
    }
    else {
        Write-Host "::Warning::$message"
    }
}

function MaskValueInLog {
    Param(
        [string] $value
    )

    if (!$runningLocal) {
        Write-Host "::add-mask::$value"
    }
}

function OutputDebug {
    Param(
        [string] $message
    )

    if ($runningLocal) {
        Write-Host $message
    }
    else {
        Write-Host "::Debug::$message"
    }
}

function GetUniqueFolderName {
    Param(
        [string] $baseFolder,
        [string] $folderName
    )

    $i = 2
    $name = $folderName
    while (Test-Path (Join-Path $baseFolder $name)) {
        $name = "$folderName($i)"
        $i++
    }
    $name
}

function stringToInt {
    Param(
        [string] $str,
        [int] $default = -1
    )

    $i = 0
    if ([int]::TryParse($str.Trim(), [ref] $i)) { 
        $i
    }
    else {
        $default
    }
}

function Expand-7zipArchive {
    Param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $DestinationPath
    )

    $7zipPath = "$env:ProgramFiles\7-Zip\7z.exe"

    $use7zip = $false
    if (Test-Path -Path $7zipPath -PathType Leaf) {
        try {
            $use7zip = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($7zipPath).FileMajorPart -ge 19
        }
        catch {
            $use7zip = $false
        }
    }

    if ($use7zip) {
        OutputDebug -message "Using 7zip"
        Set-Alias -Name 7z -Value $7zipPath
        $command = '7z x "{0}" -o"{1}" -aoa -r' -f $Path, $DestinationPath
        Invoke-Expression -Command $command | Out-Null
    }
    else {
        OutputDebug -message "Using Expand-Archive"
        Expand-Archive -Path $Path -DestinationPath "$DestinationPath" -Force
    }
}

function DownloadAndImportBcContainerHelper {
    Param(
        [string] $BcContainerHelperVersion = "",
        [string] $baseFolder = ""
    )

    $params = @{ "ExportTelemetryFunctions" = $true }
    if ($baseFolder) {
        $repoSettingsPath = Join-Path $baseFolder $repoSettingsFile
        if (-not (Test-Path $repoSettingsPath)) {
            $repoSettingsPath = Join-Path $baseFolder "..\$repoSettingsFile"
        }
        if (Test-Path $repoSettingsPath) {
            if (-not $BcContainerHelperVersion) {
                $repoSettings = Get-Content $repoSettingsPath -Encoding UTF8 | ConvertFrom-Json | ConvertTo-HashTable
                if ($repoSettings.ContainsKey("BcContainerHelperVersion")) {
                    $BcContainerHelperVersion = $repoSettings.BcContainerHelperVersion
                }
            }
            $params += @{ "bcContainerHelperConfigFile" = $repoSettingsPath }
        }
    }
    if (-not $BcContainerHelperVersion) {
        $BcContainerHelperVersion = "latest"
    }

    if ($bcContainerHelperVersion -eq "none") {
        $tempName = ""
        $module = Get-Module BcContainerHelper
        if (-not $module) {
            OutputError "When setting BcContainerHelperVersion to none, you need to ensure that BcContainerHelper is installed on the build agent"
        }

        $BcContainerHelperPath = Join-Path (Split-Path $module.Path -parent) "BcContainerHelper.ps1" -Resolve
    }
    else {
        $tempName = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
        $webclient = New-Object System.Net.WebClient
        if ($BcContainerHelperVersion -eq "dev") {
            Write-Host "Downloading BcContainerHelper developer version"
            $webclient.DownloadFile("https://github.com/microsoft/navcontainerhelper/archive/dev.zip", "$tempName.zip")
        }
        else {
            Write-Host "Downloading BcContainerHelper $BcContainerHelperVersion version"
            $webclient.DownloadFile("https://bccontainerhelper.blob.core.windows.net/public/$($BcContainerHelperVersion).zip", "$tempName.zip")        
        }
        Expand-7zipArchive -Path "$tempName.zip" -DestinationPath $tempName
        Remove-Item -Path "$tempName.zip"

        $BcContainerHelperPath = (Get-Item -Path (Join-Path $tempName "*\BcContainerHelper.ps1")).FullName
    }
    . $BcContainerHelperPath @params
    $tempName
}

function CleanupAfterBcContainerHelper {
    Param(
        [string] $bcContainerHelperPath
    )

    if ($bcContainerHelperPath) {
        try {
            Write-Host "Removing BcContainerHelper"
            Remove-Module BcContainerHelper
            Remove-Item $bcContainerHelperPath -Recurse -Force
        }
        catch {}
    }
}

function MergeCustomObjectIntoOrderedDictionary {
    Param(
        [System.Collections.Specialized.OrderedDictionary] $dst,
        [PSCustomObject] $src
    )

    # Add missing properties in OrderedDictionary

    $src.PSObject.Properties.GetEnumerator() | ForEach-Object {
        $prop = $_.Name
        $srcProp = $src."$prop"
        $srcPropType = $srcProp.GetType().Name
        if (-not $dst.Contains($prop)) {
            if ($srcPropType -eq "PSCustomObject") {
                $dst.Add("$prop", [ordered]@{})
            }
            elseif ($srcPropType -eq "Object[]") {
                $dst.Add("$prop", @())
            }
            else {
                $dst.Add("$prop", $srcProp)
            }
        }
    }

    @($dst.Keys) | ForEach-Object {
        $prop = $_
        if ($src.PSObject.Properties.Name -eq $prop) {
            $dstProp = $dst."$prop"
            $srcProp = $src."$prop"
            $dstPropType = $dstProp.GetType().Name
            $srcPropType = $srcProp.GetType().Name
            if ($srcPropType -eq "PSCustomObject" -and $dstPropType -eq "OrderedDictionary") {
                MergeCustomObjectIntoOrderedDictionary -dst $dst."$prop" -src $srcProp
            }
            elseif ($dstPropType -ne $srcPropType) {
                throw "property $prop should be of type $dstPropType, is $srcPropType."
            }
            else {
                if ($srcProp -is [Object[]]) {
                    $srcProp | ForEach-Object {
                        $srcElm = $_
                        $srcElmType = $srcElm.GetType().Name
                        if ($srcElmType -eq "PSCustomObject") {
                            $ht = [ordered]@{}
                            $srcElm.PSObject.Properties | Sort-Object -Property Name -Culture "iv-iv" | Foreach { $ht[$_.Name] = $_.Value }
                            $dst."$prop" += @($ht)
                        }
                        else {
                            $dst."$prop" += $srcElm
                        }
                    }
                }
                else {
                    $dst."$prop" = $srcProp
                }
            }
        }
    }
}

function ReadSettings {
    Param(
        [string] $baseFolder,
        [string] $repoName = "$env:GITHUB_REPOSITORY",
        [string] $workflowName = "",
        [string] $userName = ""
    )

    $repoName = $repoName.SubString("$repoName".LastIndexOf('/') + 1)
    
    # Read Settings file
    $settings = [ordered]@{
        "type"                                   = "PTE"
        "country"                                = "us"
        "artifact"                               = ""
        "companyName"                            = ""
        "repoVersion"                            = "1.0"
        "repoName"                               = $repoName
        "versioningStrategy"                     = 0
        "runNumberOffset"                        = 0
        "appBuild"                               = 0
        "appRevision"                            = 0
        "keyVaultName"                           = ""
        "licenseFileUrlSecretName"               = "LicenseFileUrl"
        "insiderSasTokenSecretName"              = "InsiderSasToken"
        "ghTokenWorkflowSecretName"              = "GhTokenWorkflow"
        "adminCenterApiCredentialsSecretName"    = "AdminCenterApiCredentials"
        "keyVaultCertificateUrlSecretName"       = ""
        "keyVaultCertificatePasswordSecretName"  = ""
        "keyVaultClientIdSecretName"             = ""
        "codeSignCertificateUrlSecretName"       = "CodeSignCertificateUrl"
        "codeSignCertificatePasswordSecretName"  = "CodeSignCertificatePassword"
        "storageContextSecretName"               = "StorageContext"
        "additionalCountries"                    = @()
        "appDependencies"                        = @()
        "appFolders"                             = @()
        "testDependencies"                       = @()
        "testFolders"                            = @()
        "installApps"                            = @()
        "installTestApps"                        = @()
        "installOnlyReferencedApps"              = $true
        "generateDependencyArtifact"             = $false
        "skipUpgrade"                            = $false
        "applicationDependency"                  = "18.0.0.0"
        "updateDependencies"                     = $false
        "installTestRunner"                      = $false
        "installTestFramework"                   = $false
        "installTestLibraries"                   = $false
        "installPerformanceToolkit"              = $false
        "enableCodeCop"                          = $false
        "enableUICop"                            = $false
        "customCodeCops"                         = @()
        "failOn"                                 = "error"
        "rulesetFile"                            = ""
        "doNotBuildTests"                        = $false
        "doNotRunTests"                          = $false
        "appSourceCopMandatoryAffixes"           = @()
        "memoryLimit"                            = ""
        "templateUrl"                            = ""
        "templateBranch"                         = ""
        "appDependencyProbingPaths"              = @()
        "githubRunner"                           = "windows-latest"
        "cacheImageName"                         = "my"
        "cacheKeepDays"                          = 3
        "alwaysBuildAllProjects"                 = $false
        "MicrosoftTelemetryConnectionString"     = $MicrosoftTelemetryConnectionString
        "PartnerTelemetryConnectionString"       = ""
        "SendExtendedTelemetryToMicrosoft"       = $false
        "Environments"                           = @()
    }

    $gitHubFolder = ".github"
    if (!(Test-Path (Join-Path $baseFolder $gitHubFolder) -PathType Container)) {
        $RepoSettingsFile = "..\$RepoSettingsFile"
        $gitHubFolder = "..\$gitHubFolder"
    }
    $workflowName = $workflowName.Split([System.IO.Path]::getInvalidFileNameChars()) -join ""
    $RepoSettingsFile, $ALGoSettingsFile, (Join-Path $gitHubFolder "$workflowName.settings.json"), (Join-Path $ALGoFolder "$workflowName.settings.json"), (Join-Path $ALGoFolder "$userName.settings.json") | ForEach-Object {
        $settingsFile = $_
        $settingsPath = Join-Path $baseFolder $settingsFile
        Write-Host "Checking $settingsFile"
        if (Test-Path $settingsPath) {
            try {
                Write-Host "Reading $settingsFile"
                $settingsJson = Get-Content $settingsPath -Encoding UTF8 | ConvertFrom-Json
       
                # check settingsJson.version and do modifications if needed
         
                MergeCustomObjectIntoOrderedDictionary -dst $settings -src $settingsJson
            }
            catch {
                throw "Settings file $settingsFile, is wrongly formatted. Error is $($_.Exception.Message)."
            }
        }
    }

    $settings
}

function AnalyzeRepo {
    Param(
        [hashTable] $settings,
        [string] $baseFolder,
        [string] $insiderSasToken,
        [switch] $doNotCheckArtifactSetting
    )

    if (!$runningLocal) {
        Write-Host "::group::Analyzing repository"
    }

    # Check applicationDependency
    [Version]$settings.applicationDependency | Out-null


    Write-Host "Checking type"
    if ($settings.type -eq "PTE") {
        if (!$settings.Contains('enablePerTenantExtensionCop')) {
            $settings.Add('enablePerTenantExtensionCop', $true)
        }
        if (!$settings.Contains('enableAppSourceCop')) {
            $settings.Add('enableAppSourceCop', $false)
        }
    }
    elseif ($settings.type -eq "AppSource App" ) {
        if (!$settings.Contains('enablePerTenantExtensionCop')) {
            $settings.Add('enablePerTenantExtensionCop', $false)
        }
        if (!$settings.Contains('enableAppSourceCop')) {
            $settings.Add('enableAppSourceCop', $true)
        }
        if ($settings.enableAppSourceCop -and (-not ($settings.appSourceCopMandatoryAffixes))) {
            throw "For AppSource Apps with AppSourceCop enabled, you need to specify AppSourceCopMandatoryAffixes in $ALGoSettingsFile"
        }
    }
    else {
        throw "The type, specified in $ALGoSettingsFile, must be either 'Per Tenant Extension' or 'AppSource App'. It is '$($settings.type)'."
    }

    $artifact = $settings.artifact
    if ($artifact.Contains('{INSIDERSASTOKEN}')) {
        if ($insiderSasToken) {
            $artifact = $artifact.replace('{INSIDERSASTOKEN}', $insiderSasToken)
        }
        else {
            throw "Artifact definition $artifact requires you to create a secret called InsiderSasToken, containing the Insider SAS Token from https://aka.ms/collaborate"
        }
    }

    if (-not (@($settings.appFolders)+@($settings.testFolders))) {
        Get-ChildItem -Path $baseFolder -Directory | Where-Object { Test-Path -Path (Join-Path $_.FullName "app.json") } | ForEach-Object {
            $folder = $_
            $appJson = Get-Content (Join-Path $folder.FullName "app.json") -Encoding UTF8 | ConvertFrom-Json
            $isTestApp = $false
            if ($appJson.PSObject.Properties.Name -eq "dependencies") {
                $appJson.dependencies | ForEach-Object {
                    if ($_.PSObject.Properties.Name -eq "AppId") {
                        $id = $_.AppId
                    }
                    else {
                        $id = $_.Id
                    }
                    if ($testRunnerApps.Contains($id)) { 
                        $isTestApp = $true
                    }
                }
            }
            if ($isTestApp) {
                $settings.testFolders += @($_.Name)
            }
            else {
                $settings.appFolders += @($_.Name)
            }
        }
    }

    Write-Host "Checking appFolders and testFolders"
    $dependencies = [ordered]@{}
    $true, $false | ForEach-Object {
        $appFolder = $_
        if ($appFolder) {
            $folders = @($settings.appFolders)
            $descr = "App folder"
        }
        else {
            $folders = @($settings.testFolders)
            $descr = "Test folder"
        }
        $folders | ForEach-Object {
            $folderName = $_
            if ($dependencies.Contains($folderName)) {
                throw "$descr $folderName, specified in $ALGoSettingsFile, is specified more than once."
            }
            $folder = Join-Path $baseFolder $folderName
            $appJsonFile = Join-Path $folder "app.json"
            $removeFolder = $false
            if (-not (Test-Path $folder -PathType Container)) {
                OutputWarning -message "$descr $folderName, specified in $ALGoSettingsFile, does not exist."
                $removeFolder = $true
            }
            elseif (-not (Test-Path $appJsonFile -PathType Leaf)) {
                OutputWarning -message "$descr $folderName, specified in $ALGoSettingsFile, does not contain the source code for an app (no app.json file)."
                $removeFolder = $true
            }
            if ($removeFolder) {
                if ($appFolder) {
                    $settings.appFolders = @($settings.appFolders | Where-Object { $_ -ne $folderName })
                }
                else {
                    $settings.testFolders = @($settings.testFolders | Where-Object { $_ -ne $folderName })
                }
            }
            else {
                $dependencies.Add("$folderName", @())
                try {
                    $appJson = Get-Content $appJsonFile -Encoding UTF8 | ConvertFrom-Json
                    if ($appJson.PSObject.Properties.Name -eq 'Dependencies') {
                        $appJson.dependencies | ForEach-Object {
                            if ($_.PSObject.Properties.Name -eq "AppId") {
                                $id = $_.AppId
                            }
                            else {
                                $id = $_.Id
                            }
                            if ($id -eq $applicationAppId) {
                                if ([Version]$_.Version -gt [Version]$settings.applicationDependency) {
                                    $settings.applicationDependency = $appDep
                                }
                            }
                            else {
                                $dependencies."$folderName" += @( [ordered]@{ "id" = $id; "version" = $_.version } )
                            }
                        }
                    }
                    if ($appJson.PSObject.Properties.Name -eq 'Application') {
                        $appDep = $appJson.application
                        if ([Version]$appDep -gt [Version]$settings.applicationDependency) {
                            $settings.applicationDependency = $appDep
                        }
                    }
                }
                catch {
                    throw "$descr $folderName, specified in $ALGoSettingsFile, contains a corrupt app.json file. Error is $($_.Exception.Message)."
                }
            }
        }
    }
    Write-Host "Application Dependency $($settings.applicationDependency)"

    if (!$doNotCheckArtifactSetting) {
        Write-Host "Checking artifact setting"
        if ($artifact -eq "" -and $settings.updateDependencies) {
            $artifact = Get-BCArtifactUrl -country $settings.country -select all | Where-Object { [Version]$_.Split("/")[4] -ge [Version]$settings.applicationDependency } | Select-Object -First 1
            if (-not $artifact) {
                if ($insiderSasToken) {
                    $artifact = Get-BCArtifactUrl -storageAccount bcinsider -country $settings.country -select all -sasToken $insiderSasToken | Where-Object { [Version]$_.Split("/")[4] -ge [Version]$settings.applicationDependency } | Select-Object -First 1
                    if (-not $artifact) {
                        throw "No artifacts found for application dependency $($settings.applicationDependency)."
                    }
                }
                else {
                    throw "No artifacts found for application dependency $($settings.applicationDependency). If you are targetting an insider version, you need to create a secret called InsiderSasToken, containing the Insider SAS Token from https://aka.ms/collaborate"
                }
            }
        }
        
        if ($artifact -like "https://*") {
            $artifactUrl = $artifact
            $storageAccount = ("$artifactUrl////".Split('/')[2]).Split('.')[0]
            $artifactType = ("$artifactUrl////".Split('/')[3])
            $version = ("$artifactUrl////".Split('/')[4])
            $country = ("$artifactUrl////".Split('/')[5])
            $sasToken = "$($artifactUrl)?".Split('?')[1]
        }
        else {
            $segments = "$artifact/////".Split('/')
            $storageAccount = $segments[0];
            $artifactType = $segments[1]; if ($artifactType -eq "") { $artifactType = 'Sandbox' }
            $version = $segments[2]
            $country = $segments[3]; if ($country -eq "") { $country = $settings.country }
            $select = $segments[4]; if ($select -eq "") { $select = "latest" }
            $sasToken = $segments[5]
            $artifactUrl = Get-BCArtifactUrl -storageAccount $storageAccount -type $artifactType -version $version -country $country -select $select -sasToken $sasToken | Select-Object -First 1
            if (-not $artifactUrl) {
                throw "No artifacts found for the artifact setting ($artifact) in $ALGoSettingsFile"
            }
            $version = $artifactUrl.Split('/')[4]
            $storageAccount = $artifactUrl.Split('/')[2]
        }
    
        if ($settings.additionalCountries -or $country -ne $settings.country) {
            if ($country -ne $settings.country) {
                OutputWarning -message "artifact definition in $ALGoSettingsFile uses a different country ($country) than the country definition ($($settings.country))"
            }
            Write-Host "Checking Country and additionalCountries"
            # AT is the latest published language - use this to determine available country codes (combined with mapping)
            $ver = [Version]$version
            Write-Host "https://$storageAccount/$artifactType/$version/$country"
            $atArtifactUrl = Get-BCArtifactUrl -storageAccount $storageAccount -type $artifactType -country at -version "$($ver.Major).$($ver.Minor)" -select Latest -sasToken $sasToken
            Write-Host "Latest AT artifacts $atArtifactUrl"
            $latestATversion = $atArtifactUrl.Split('/')[4]
            $countries = Get-BCArtifactUrl -storageAccount $storageAccount -type $artifactType -version $latestATversion -sasToken $sasToken -select All | ForEach-Object { 
                $countryArtifactUrl = $_.Split('?')[0] # remove sas token
                $countryArtifactUrl.Split('/')[5] # get country
            }
            Write-Host "Countries with artifacts $($countries -join ',')"
            $allowedCountries = $bcContainerHelperConfig.mapCountryCode.PSObject.Properties.Name + $countries | Select-Object -Unique
            Write-Host "Allowed Country codes $($allowedCountries -join ',')"
            if ($allowedCountries -notcontains $settings.country) {
                throw "Country ($($settings.country)), specified in $ALGoSettingsFile is not a valid country code."
            }
            $illegalCountries = $settings.additionalCountries | Where-Object { $allowedCountries -notcontains $_ }
            if ($illegalCountries) {
                throw "additionalCountries contains one or more invalid country codes ($($illegalCountries -join ",")) in $ALGoSettingsFile."
            }
            $artifactUrl = $artifactUrl.Replace($artifactUrl.Split('/')[4],$atArtifactUrl.Split('/')[4])
        }
        else {
            Write-Host "Downloading artifacts from $($artifactUrl.Split('?')[0])"
            $folders = Download-Artifacts -artifactUrl $artifactUrl -includePlatform -ErrorAction SilentlyContinue
            if (-not ($folders)) {
                throw "Unable to download artifacts from $($artifactUrl.Split('?')[0]), please check $ALGoSettingsFile."
            }
        }
        $settings.artifact = $artifactUrl

        if ([Version]$settings.applicationDependency -gt [Version]$version) {
            throw "Application dependency is set to $($settings.applicationDependency), which isn't compatible with the artifact version $version"
        }
    }

    # unpack all dependencies and update app- and test dependencies from dependency apps
    $settings.appDependencies + $settings.testDependencies | ForEach-Object {
        $dep = $_
        if ($dep -is [string]) {
            # TODO: handle pre-settings - documentation pending
        }
    }

    Write-Host "Updating app- and test Dependencies"
    $dependencies.Keys | ForEach-Object {
        $folderName = $_
        $appFolder = $settings.appFolders.Contains($folderName)
        if ($appFolder) { $prop = "appDependencies" } else { $prop = "testDependencies" }
        $dependencies."$_" | ForEach-Object {
            $id = $_.Id
            $version = $_.version
            $exists = $settings."$prop" | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] -and $_.id -eq $id }
            if ($exists) {
                if ([Version]$version -gt [Version]$exists.Version) {
                    $exists.Version = $version
                }
            }
            else {
                $settings."$prop" += @( [ordered]@{ "id" = $id; "version" = $_.version } )
            }
        }
    }

    Write-Host "Analyzing Test App Dependencies"
    if ($settings.testFolders) { $settings.installTestRunner = $true }

    $settings.appDependencies + $settings.testDependencies | ForEach-Object {
        $dep = $_
        if ($dep.GetType().Name -eq "OrderedDictionary") {
            if ($testRunnerApps.Contains($dep.id)) { $settings.installTestRunner = $true }
            if ($testFrameworkApps.Contains($dep.id)) { $settings.installTestFramework = $true }
            if ($testLibrariesApps.Contains($dep.id)) { $settings.installTestLibraries = $true }
            if ($performanceToolkitApps.Contains($dep.id)) { $settings.installPerformanceToolkit = $true }
        }
    }

    if (-not $settings.testFolders) {
        OutputWarning -message "No test apps found in testFolders in $ALGoSettingsFile"
        $doNotRunTests = $true
    }
    if (-not $settings.appFolders) {
        OutputWarning -message "No apps found in appFolders in $ALGoSettingsFile"
    }

    $settings
    if (!$runningLocal) {
        Write-Host "::endgroup::"
    }
}

function installModules {
    Param(
        [String[]] $modules
    )

    $modules | ForEach-Object {
        if (-not (get-installedmodule -Name $_ -ErrorAction SilentlyContinue)) {
            Write-Host "Installing module $_"
            Install-Module $_ -Force | Out-Null
        }
    }
    $modules | ForEach-Object { 
        Write-Host "Importing module $_"
        Import-Module $_ -DisableNameChecking -WarningAction SilentlyContinue | Out-Null
    }
}

function CloneIntoNewFolder {
    Param(
        [string] $actor,
        [string] $token,
        [string] $branch
    )

    $baseFolder = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
    New-Item $baseFolder -ItemType Directory | Out-Null
    Set-Location $baseFolder
    $serverUri = [Uri]::new($env:GITHUB_SERVER_URL)
    $serverUrl = "$($serverUri.Scheme)://$($actor):$($token)@$($serverUri.Host)/$($env:GITHUB_REPOSITORY)"

    # Environment variables for hub commands
    $env:GITHUB_USER = $actor
    $env:GITHUB_TOKEN = $token

    # Configure git username and email
    invoke-git config --global user.email "$actor@users.noreply.github.com"
    invoke-git config --global user.name "$actor"

    # Configure hub to use https
    invoke-git config --global hub.protocol https

    invoke-git clone $serverUrl

    Set-Location *

    if ($branch) {
        invoke-git checkout -b $branch
    }

    $serverUrl
}

function CommitFromNewFolder {
    Param(
        [string] $serverUrl,
        [string] $commitMessage,
        [string] $branch
    )

    invoke-git add *
    if ($commitMessage.Length -gt 250) {
        $commitMessage = "$($commitMessage.Substring(0,250))...)"
    }
    invoke-git commit --allow-empty -m "'$commitMessage'"
    if ($branch) {
        invoke-git push -u $serverUrl $branch
        invoke-gh pr create --fill --head $branch --repo $env:GITHUB_REPOSITORY
    }
    else {
        invoke-git push $serverUrl
    }
}

function Select-Value {
    Param(
        [Parameter(Mandatory=$false)]
        [string] $title,
        [Parameter(Mandatory=$false)]
        [string] $description,
        [Parameter(Mandatory=$true)]
        $options,
        [Parameter(Mandatory=$false)]
        [string] $default = "",
        [Parameter(Mandatory=$true)]
        [string] $question
    )

    if ($title) {
        Write-Host -ForegroundColor Yellow $title
        Write-Host -ForegroundColor Yellow ("-"*$title.Length)
    }
    if ($description) {
        Write-Host $description
        Write-Host
    }
    $offset = 0
    $keys = @()
    $values = @()

    $options.GetEnumerator() | ForEach-Object {
        Write-Host -ForegroundColor Yellow "$([char]($offset+97)) " -NoNewline
        $keys += @($_.Key)
        $values += @($_.Value)
        if ($_.Key -eq $default) {
            Write-Host -ForegroundColor Yellow $_.Value
            $defaultAnswer = $offset
        }
        else {
            Write-Host $_.Value
        }
        $offset++     
    }
    Write-Host
    $answer = -1
    do {
        Write-Host "$question " -NoNewline
        if ($defaultAnswer -ge 0) {
            Write-Host "(default $([char]($defaultAnswer + 97))) " -NoNewline
        }
        $selection = (Read-Host).ToLowerInvariant()
        if ($selection -eq "") {
            if ($defaultAnswer -ge 0) {
                $answer = $defaultAnswer
            }
            else {
                Write-Host -ForegroundColor Red "No default value exists. " -NoNewline
            }
        }
        else {
            if (($selection.Length -ne 1) -or (([int][char]($selection)) -lt 97 -or ([int][char]($selection)) -ge (97+$offset))) {
                Write-Host -ForegroundColor Red "Illegal answer. " -NoNewline
            }
            else {
                $answer = ([int][char]($selection))-97
            }
        }
        if ($answer -eq -1) {
            if ($offset -eq 2) {
                Write-Host -ForegroundColor Red "Please answer one letter, a or b"
            }
            else {
                Write-Host -ForegroundColor Red "Please answer one letter, from a to $([char]($offset+97-1))"
            }
        }
    } while ($answer -eq -1)

    Write-Host -ForegroundColor Green "$($values[$answer]) selected"
    Write-Host
    $keys[$answer]
}

function Enter-Value {
    Param(
        [Parameter(Mandatory=$false)]
        [string] $title,
        [Parameter(Mandatory=$false)]
        [string] $description,
        [Parameter(Mandatory=$false)]
        $options,
        [Parameter(Mandatory=$false)]
        [string] $default = "",
        [Parameter(Mandatory=$true)]
        [string] $question,
        [switch] $doNotConvertToLower,
        [switch] $previousStep
    )

    if ($title) {
        Write-Host -ForegroundColor Yellow $title
        Write-Host -ForegroundColor Yellow ("-"*$title.Length)
    }
    if ($description) {
        Write-Host $description
        Write-Host
    }
    $answer = ""
    do {
        Write-Host "$question " -NoNewline
        if ($options) {
            Write-Host "($([string]::Join(', ', $options))) " -NoNewline
        }
        if ($default) {
            Write-Host "(default $default) " -NoNewline
        }
        if ($doNotConvertToLower) {
            $selection = Read-Host
        }
        else {
            $selection = (Read-Host).ToLowerInvariant()
        }
        if ($selection -eq "") {
            if ($default) {
                $answer = $default
            }
            else {
                Write-Host -ForegroundColor Red "No default value exists. "
            }
        }
        else {
            if ($options) {
                $answer = $options | Where-Object { $_ -like "$selection*" }
                if (-not ($answer)) {
                    Write-Host -ForegroundColor Red "Illegal answer. Please answer one of the options."
                }
                elseif ($answer -is [Array]) {
                    Write-Host -ForegroundColor Red "Multiple options match the answer. Please answer one of the options that matched the previous selection."
                    $options = $answer
                    $answer = $null
                }
            }
            else {
                $answer = $selection
            }
        }
    } while (-not ($answer))

    Write-Host -ForegroundColor Green "$answer selected"
    Write-Host
    $answer
}

function GetContainerName([string] $project) {
    "bc$($project -replace "\W")$env:GITHUB_RUN_ID"
}

function CreateDevEnv {
    Param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('local','cloud')]
        [string] $kind,
        [ValidateSet('local','GitHubActions')]
        [string] $caller = 'local',
        [Parameter(Mandatory=$true)]
        [string] $baseFolder,
        [string] $userName = $env:Username,
        [string] $bcContainerHelperPath = "",

        [Parameter(ParameterSetName='cloud')]
        [Hashtable] $bcAuthContext = $null,
        [Parameter(ParameterSetName='cloud')]
        [Hashtable] $adminCenterApiCredentials = @{},
        [Parameter(Mandatory=$true, ParameterSetName='cloud')]
        [string] $environmentName,
        [Parameter(ParameterSetName='cloud')]
        [switch] $reuseExistingEnvironment,

        [Parameter(Mandatory=$true, ParameterSetName='local')]
        [ValidateSet('Windows','UserPassword')]
        [string] $auth,
        [Parameter(Mandatory=$true, ParameterSetName='local')]
        [pscredential] $credential,
        [Parameter(ParameterSetName='local')]
        [string] $containerName = "",
        [string] $insiderSasToken = "",
        [string] $LicenseFileUrl = ""
    )

    if ($PSCmdlet.ParameterSetName -ne $kind) {
        throw "Specified parameters doesn't match kind=$kind"
    }

    $runAlPipelineParams = @{}
    $loadBcContainerHelper = ($bcContainerHelperPath -eq "")
    if ($loadBcContainerHelper) {
        $BcContainerHelperPath = DownloadAndImportBcContainerHelper -baseFolder $baseFolder
    }
    try {
        if ($caller -eq "local") {
            $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                Check-BcContainerHelperPermissions -silent -fix
            }
        }

        $workflowName = "$($kind)DevEnv"
        $params = @{
            "baseFolder" = $baseFolder
            "workflowName" = $workflowName
        }
        if ($caller -eq "local") { $params += @{ "userName" = $userName } }
        $settings = ReadSettings @params
    
        if ($caller -eq "GitHubActions") {
            if ($kind -ne "cloud") {
                OutputError -message "Unexpected. kind=$kind, caller=$caller"
                exit
            }
            if ($adminCenterApiCredentials.Keys.Count -eq 0) {
                OutputError -message "You need to add a secret called AdminCenterApiCredentials containing authentication for the admin Center API."
                exit
            }
        }
        else {
            if (($settings.keyVaultName) -and -not ($bcAuthContext)) {
                Write-Host "Reading Key Vault $($settings.keyVaultName)"
                installModules -modules @('Az.KeyVault')

                if ($kind -eq "local") {
                    $LicenseFileSecret = Get-AzKeyVaultSecret -VaultName $settings.keyVaultName -Name $settings.LicenseFileUrlSecretName
                    if ($LicenseFileSecret) { $LicenseFileUrl = $LicenseFileSecret.SecretValue | Get-PlainText }

                    $insiderSasTokenSecret = Get-AzKeyVaultSecret -VaultName $settings.keyVaultName -Name $settings.InsiderSasTokenSecretName
                    if ($insiderSasTokenSecret) { $insiderSasToken = $insiderSasTokenSecret.SecretValue | Get-PlainText }

                    # do not add codesign cert.
                    
                    if ($settings.KeyVaultCertificateUrlSecretName) {
                        $KeyVaultCertificateUrlSecret = Get-AzKeyVaultSecret -VaultName $settings.keyVaultName -Name $settings.KeyVaultCertificateUrlSecretName
                        if ($KeyVaultCertificateUrlSecret) {
                            $keyVaultCertificatePasswordSecret = Get-AzKeyVaultSecret -VaultName $settings.keyVaultName -Name $settings.keyVaultCertificatePasswordSecretName
                            $keyVaultClientIdSecret = Get-AzKeyVaultSecret -VaultName $settings.keyVaultName -Name $settings.keyVaultClientIdSecretName
                            if (-not ($keyVaultCertificatePasswordSecret) -or -not ($keyVaultClientIdSecret)) {
                                OutputError -message "When specifying a KeyVaultCertificateUrl secret in settings, you also need to provide a KeyVaultCertificatePassword secret and a KeyVaultClientId secret"
                                exit
                            }
                            $runAlPipelineParams += @{ 
                                "KeyVaultCertPfxFile" = $KeyVaultCertificateUrlSecret.SecretValue | Get-PlainText
                                "keyVaultCertPfxPassword" = $keyVaultCertificatePasswordSecret.SecretValue
                                "keyVaultClientId" = $keyVaultClientIdSecret.SecretValue | Get-PlainText
                            }
                        }
                    }
                }
                elseif ($kind -eq "cloud") {
                    $adminCenterApiCredentialsSecret = Get-AzKeyVaultSecret -VaultName $settings.keyVaultName -Name $settings.AdminCenterApiCredentialsSecretName
                    if ($adminCenterApiCredentialsSecret) { $AdminCenterApiCredentials = $adminCenterApiCredentialsSecret.SecretValue | Get-PlainText | ConvertFrom-Json | ConvertTo-HashTable }
                    $legalParameters = @("RefreshToken","CliendId","ClientSecret","deviceCode")
                    $adminCenterApiCredentials.Keys | ForEach-Object {
                        if (-not ($legalParameters -contains $_)) {
                            throw "$_ is an illegal property in adminCenterApiCredentials setting"
                        }
                    }
                    if ($adminCenterApiCredentials.ContainsKey('ClientSecret')) {
                        $adminCenterApiCredentials.ClientSecret = ConvertTo-SecureString -String $AdminCenterApiCredentials.ClientSecret -AsPlainText -Force
                    }
                }
            }
        }

        $params = @{
            "settings" = $settings
            "baseFolder" = $baseFolder
        }
        if ($kind -eq "local") {
            $params += @{
                "insiderSasToken" = $insiderSasToken
            }
        }
        elseif ($kind -eq "cloud") {
            $params += @{
                "doNotCheckArtifactSetting" = $true
            }
        }
        $repo = AnalyzeRepo @params
        if ((-not $repo.appFolders) -and (-not $repo.testFolders)) {
            Write-Host "Repository is empty, exiting"
            exit
        }

        if ($kind -eq "local" -and $repo.type -eq "AppSource App" ) {
            if ($licenseFileUrl -eq "") {
                OutputError -message "When building an AppSource App, you need to create a secret called LicenseFileUrl, containing a secure URL to your license file with permission to the objects used in the app."
                exit
            }
        }

        $installApps = $repo.installApps
        $installTestApps = $repo.installTestApps

        if ($repo.versioningStrategy -eq -1) {
            if ($kind -eq "cloud") { throw "Versioningstrategy -1 cannot be used on cloud" }
            $artifactVersion = [Version]$repo.artifact.Split('/')[4]
            $runAlPipelineParams += @{
                "appVersion" = "$($artifactVersion.Major).$($artifactVersion.Minor)"
                "appBuild" = "$($artifactVersion.Build)"
                "appRevision" = "$($artifactVersion.Revision)"
            }
        }
        elseif (($repo.versioningStrategy -band 16) -eq 16) {
            $runAlPipelineParams += @{
                "appVersion" = $repo.repoVersion
            }
        }

        $buildArtifactFolder = Join-Path $baseFolder "output"
        if (Test-Path $buildArtifactFolder) {
            Get-ChildItem -Path $buildArtifactFolder -Include * -File | ForEach-Object { $_.Delete()}
        }
        else {
            New-Item $buildArtifactFolder -ItemType Directory | Out-Null
        }
    
        $allTestResults = "testresults*.xml"
        $testResultsFile = Join-Path $baseFolder "TestResults.xml"
        $testResultsFiles = Join-Path $baseFolder $allTestResults
        if (Test-Path $testResultsFiles) {
            Remove-Item $testResultsFiles -Force
        }
    
        Set-Location $baseFolder
        $runAlPipelineOverrides | ForEach-Object {
            $scriptName = $_
            $scriptPath = Join-Path $ALGoFolder "$ScriptName.ps1"
            if (Test-Path -Path $scriptPath -Type Leaf) {
                Write-Host "Add override for $scriptName"
                $runAlPipelineParams += @{
                    "$scriptName" = (Get-Command $scriptPath | Select-Object -ExpandProperty ScriptBlock)
                }
            }
        }

        if ($kind -eq "local") {
            $runAlPipelineParams += @{
                "artifact" = $repo.artifact.replace('{INSIDERSASTOKEN}',$insiderSasToken)
                "auth" = $auth
                "credential" = $credential
            }
            if ($containerName) {
                $runAlPipelineParams += @{
                    "updateLaunchJson" = "Local Sandbox ($containerName)"
                    "containerName" = $containerName
                }
            }
            else {
                $runAlPipelineParams += @{
                    "updateLaunchJson" = "Local Sandbox"
                }
            }
        }
        elseif ($kind -eq "cloud") {
            if ($runAlPipelineParams.ContainsKey('NewBcContainer')) {
                throw "Overriding NewBcContainer is not allowed when running cloud DevEnv"
            }
            
            if ($bcAuthContext) {
                 $authContext = Renew-BcAuthContext $bcAuthContext
            }
            else {
                $authContext = New-BcAuthContext @AdminCenterApiCredentials -includeDeviceLogin:($caller -eq "local")
            }

            $existingEnvironment = Get-BcEnvironments -bcAuthContext $authContext | Where-Object { $_.Name -eq $environmentName }
            if ($existingEnvironment) {
                if ($existingEnvironment.type -ne "Sandbox") {
                    throw "Environment $environmentName already exists and it is not a sandbox environment"
                }
                if (!$reuseExistingEnvironment) {
                    Remove-BcEnvironment -bcAuthContext $authContext -environment $environmentName
                    $existingEnvironment = $null
                }
            }
            if ($existingEnvironment) {
                $countryCode = $existingEnvironment.CountryCode.ToLowerInvariant()
                $baseApp = Get-BcPublishedApps -bcAuthContext $authContext -environment $environmentName | Where-Object { $_.Name -eq "Base Application" }
            }
            else {
                $countryCode = $repo.country
                New-BcEnvironment -bcAuthContext $authContext -environment $environmentName -countryCode $countryCode -environmentType "Sandbox" | Out-Null
                do {
                    Start-Sleep -Seconds 10
                    $baseApp = Get-BcPublishedApps -bcAuthContext $authContext -environment $environmentName | Where-Object { $_.Name -eq "Base Application" }
                } while (!($baseApp))
                $baseapp | Out-Host
            }
            
            $artifact = Get-BCArtifactUrl `
                -country $countryCode `
                -version $baseApp.Version `
                -select Closest
            
            if ($artifact) {
                Write-Host "Using Artifacts: $artifact"
            }
            else {
                throw "No artifacts available"
            }

            $runAlPipelineParams += @{
                "artifact" = $artifact
                "bcAuthContext" = $authContext
                "environment" = $environmentName
                "containerName" = "bcServerFilesOnly"
                "updateLaunchJson" = "Cloud Sandbox ($environmentName)"
            }
        }
        
        Run-AlPipeline @runAlPipelineParams `
            -pipelinename $workflowName `
            -imageName "" `
            -memoryLimit $repo.memoryLimit `
            -baseFolder $baseFolder `
            -licenseFile $LicenseFileUrl `
            -installApps $installApps `
            -installTestApps $installTestApps `
            -installOnlyReferencedApps:$repo.installOnlyReferencedApps `
            -appFolders $repo.appFolders `
            -testFolders $repo.testFolders `
            -testResultsFile $testResultsFile `
            -testResultsFormat 'JUnit' `
            -installTestRunner:$repo.installTestRunner `
            -installTestFramework:$repo.installTestFramework `
            -installTestLibraries:$repo.installTestLibraries `
            -installPerformanceToolkit:$repo.installPerformanceToolkit `
            -enableCodeCop:$repo.enableCodeCop `
            -enableAppSourceCop:$repo.enableAppSourceCop `
            -enablePerTenantExtensionCop:$repo.enablePerTenantExtensionCop `
            -enableUICop:$repo.enableUICop `
            -customCodeCops:$repo.customCodeCops `
            -azureDevOps:($caller -eq 'AzureDevOps') `
            -gitLab:($caller -eq 'GitLab') `
            -gitHubActions:($caller -eq 'GitHubActions') `
            -failOn $repo.failOn `
            -rulesetFile $repo.rulesetFile `
            -AppSourceCopMandatoryAffixes $repo.appSourceCopMandatoryAffixes `
            -doNotRunTests `
            -useDevEndpoint `
            -keepContainer
    }
    finally {
        if ($loadBcContainerHelper) {
            CleanupAfterBcContainerHelper -bcContainerHelperPath $bcContainerHelperPath
        }
    }
}

function ConvertTo-HashTable() {
    [CmdletBinding()]
    Param(
        [parameter(ValueFromPipeline)]
        [PSCustomObject] $object
    )
    $ht = @{}
    if ($object) {
        $object.PSObject.Properties | Foreach { $ht[$_.Name] = $_.Value }
    }
    $ht
}

function CheckAndCreateProjectFolder {
    Param(
        [string] $project
    )

    if (-not $project) { $project -eq "." }
    if ($project -ne ".") {
        if (Test-Path $ALGoSettingsFile) {
            Write-Host "Reading $ALGoSettingsFile"
            $settingsJson = Get-Content $ALGoSettingsFile -Encoding UTF8 | ConvertFrom-Json
            if ($settingsJson.appFolders.Count -eq 0 -and $settingsJson.testFolders.Count -eq 0) {
                OutputWarning "Converting the repository to a multi-project repository as no other apps have been added previously."
                New-Item $project -ItemType Directory | Out-Null
                Move-Item -path $ALGoFolder -Destination $project
                Set-Location $project
            }
            else {
                throw "Repository is setup for a single project, cannot add a project. Move all appFolders, testFolders and the .AL-Go folder to a subdirectory in order to convert to a multi-project repository."
            }
        }
        else {
            if (!(Test-Path $project)) {
                New-Item -Path (Join-Path $project $ALGoFolder) -ItemType Directory | Out-Null
                Set-Location $project
                OutputWarning "Project folder doesn't exist, creating a new project folder and a default settings file with country us. Please modify if needed."
                [ordered]@{
                    "country" = "us"
                    "appFolders" = @()
                    "testFolders" = @()
                } | ConvertTo-Json | Set-Content $ALGoSettingsFile -Encoding UTF8
            }
            else {
                Set-Location $project
            }
        }
    }
}
