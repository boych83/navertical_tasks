[CmdletBinding()]
param()

Trace-VstsEnteringInvocation $MyInvocation

try {
    # Get inputs.
    $ContainerName = Get-VstsInput -Name 'ContainerName' -Require
    #$Contents = Get-VstsInput -Name 'Contents' -Default '*.app'
    $SourceFolder = Get-VstsInput -Name 'SourceFolder' -Default $env:SYSTEM_DEFAULTWORKINGDIRECTORY
    #$AppFileExclude = Get-VstsInput -Name 'AppFileExclude' -Default ''
    $Tenant = Get-VstsInput -Name 'Tenant' -Default 'default'
    $SyncMode = Get-VstsInput -Name 'SyncMode' -Default 'Add'
    $Scope = Get-VstsInput -Name 'Scope' -Default 'Tenant'
    $SkipVerify = Get-VstsInput -Name 'SkipVerify' -AsBool -Default $false
    $Recurse = Get-VstsInput -Name 'Recurse' -AsBool -Default $false
    $UseDevEndpoint = Get-VstsInput -Name 'UseDevEndpoint' -AsBool -Default $false
    $AppDownloadScript = Get-VstsInput -Name 'AppDownloadScript' -Default ''

    Write-Host "Importing module NVRAppDevOps"
    Import-Module NVRAppDevOps -DisableNameChecking
    
    # Create fast container to be able to get the al app order
    $PWord = ConvertTo-SecureString -String 'Pass@word1' -AsPlainText -Force
    $User = $env:USERNAME
    $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User,$PWord
    try {

        if (Get-NavContainerPath -containerName $ContainerName -path $SourceFolder) {
            $OrderContainerName = $ContainerName
        } else {
            $InternalContainerName = 'BCPS'
            $RepoPath = $SourceFolder
            $RepoPath = Split-Path -Path $RepoPath -Resolve
            Write-Host "Creating internal container with $RepoPath shared"
            New-NavContainer -accept_eula `
                -accept_outdated `
                -containerName $InternalContainerName `
                -imageName (Get-NavContainerImageName -containerName $ContainerName) `
                -doNotExportObjectsToText `
                -alwaysPull `
                -shortcuts "None" `
                -auth 'Windows' `
                -Credential $cred `
                -memoryLimit '4GB' `
                -updateHosts `
                -useBestContainerOS `
                -additionalParameters @("--volume ""$($RepoPath):c:\app""") `
                -myScripts  @(@{"navstart.ps1" = "Write-Host 'Ready for connections!'";"checkhealth.ps1" = "exit 0"})
    
            $OrderContainerName = $InternalContainerName
        }
        Write-Host 'Getting app dependencies and order'
        $AppOrder = Get-ALAppOrder -ContainerName $OrderContainerName -Path $SourceFolder -Recurse:$Recurse

        #Publish-ALAppTree -ContainerName $ContainerName `
        #                  -SkipVerification:$skipverify `
        #                  -OrderedApps $AppOrder `
        #                  -PackagesPath $SourceFolder `
        #                  -syncMode $SyncMode `
        #                  -scope $Scope `
        #                  -AppDownloadScript $AppDownloadScript `
        #                  -UseDevEndpoint:$UseDevEndpoint `
        #                  -Tenant $Tenant
        Write-Host "Checking availability of dependencies ($($AppOrder.Count))..."
        foreach ($App in ($AppOrder |where-object {$_.publisher -ne 'Microsoft'})) {
            if ($App.AppPath -like '*.app') {
                $AppFile = $App.AppPath
            }
            else {
                $AppFile = (Get-ChildItem -Path $SourceFolder -Filter "$($App.publisher)_$($App.name)_*.app" | Select-Object -First 1).FullName
            }
            $dockerapp = Get-NavContainerAppInfo -containerName $ContainerName -tenantSpecificProperties -sort None | where-object { $_.Name -eq $App.name }
            if ((-not $AppFile) -and (-not $dockerapp)) {
                Write-Host "App $($App.name) from $($App.publisher) not found."
                if ($AppDownloadScript) {
                    Write-Host "Trying to download..."
                    Download-ALApp -name $App.name -publisher $App.publisher -version $App.version -targetPath $SourceFolder -AppDownloadScript $AppDownloadScript
                    $AppFile = (Get-ChildItem -Path $SourceFolder -Filter "$($App.publisher)_$($App.name)_*.app" | Select-Object -First 1).FullName
                    $App.AppPath = $AppFile               
                }
            } else {
                if (-not $dockerapp) {
                    Write-Host "$($App.name) found as file $($App.AppPath)"
                } else {
                    Write-Host "$($App.name) found already installed"
                }
    
            }
        }
    
        Write-Host "Getting dependencies after download"
        $AppOrder = Get-ALAppOrder -ContainerName $OrderContainerName -Path $SourceFolder -Recurse:$Recurse
    
        Write-Host "Publishing and Installing the apps..."
        foreach ($App in ($AppOrder |where-object {$_.publisher -ne 'Microsoft'})) {
            if ($App.AppPath -like '*.app') {
                $AppFile = $App.AppPath
            }
            else {
                $AppFile = (Get-ChildItem -Path $SourceFolder -Filter "$($App.publisher)_$($App.name)_*.app" | Select-Object -First 1).FullName
            }
            $dockerapp = Get-NavContainerAppInfo -containerName $ContainerName -tenantSpecificProperties -sort None | where-object { $_.Name -eq $App.name }
    
            $install = -not $dockerapp
            if ($AppFile) {
                if ($install) {
                    Write-Host "App not exists on server, will install by default"
                } else {
                    Write-Host "Another version exists on server, will do upgrade"
                }
                Publish-NavContainerApp -containerName $ContainerName `
                                        -appFile $AppFile `
                                        -skipVerification:$SkipVerify `
                                        -sync `
                                        -install:$install `
                                        -syncMode $SyncMode `
                                        -tenant $Tenant `
                                        -scope $Scope `
                                        -useDevEndpoint:$UseDevEndpoint
            
                if ($dockerapp) {
                    $dockerapp = Get-NavContainerAppInfo -containerName $ContainerName -tenantSpecificProperties -sort None | where-object { $_.Name -eq $App.name } | Sort-Object -Property "Version" | Select-Object -Unique -Property *
                    if ($dockerapp.Count -gt 1) {
                        $newInstalledApp = $null
                        foreach ($dapp in $dockerapp) {
                            if ($dapp.IsInstalled) {
                                $previousVersion = $dapp
                            }
                            if (($AppFile.Contains($dapp.Version)) -and (-not $newInstalledApp) -and $previousVersion) {
                                Write-Host "Upgrading from $($previousVersion.Version) to $($dapp.Version)"
                                Start-NavContainerAppDataUpgrade -containerName $ContainerName -appName $App.name -appVersion $dapp.Version
                                $newInstalledApp = $dapp
                            }
                        }
                        foreach ($uapp in $dockerapp) {
                            if ($uapp.Version -ne $newInstalledApp.Version) {
                                Write-Host "Unpublishing version $($uapp.Version) if possible"
                                Unpublish-NavContainerApp -containerName $ContainerName -appName $App.name -version $uapp.Version -ErrorAction SilentlyContinue
                            }
                        }
                    }
                }
            } else {
                if ($dockerapp) {
                    Write-Host "Using installed version of $($App.name) from $($App.publisher)"
                } else {
                    Write-Error "App $($App.name) from $($App.publisher) is missing!"
                }
            }
        }
    } finally  {
        if ($InternalContainerName) {
            Write-Host 'Remove internal container'
            Remove-NavContainer -containerName $InternalContainerName
        }
    }
         

}
finally {
    Trace-VstsLeavingInvocation $MyInvocation
}
