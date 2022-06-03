<#
.Synopsis
    Provides ability to un-cleanup expired sections

.Requirements
    This input file will require the sections Object ID and the required Section ID.
    Headers are:
        GraphId | SectionId
    
    This does conform to the SectionUsage.csv file format.

.Example
    .\Unrename-Expired_Classes.ps1 -SectionsToUpdateFilePath "C:\SectionUsage.csv" -SDSExpiredPrefix "Exp0721_"
#>

Param (
    [switch] $PPE = $false,
    [Parameter(Mandatory=$false)]
    [string] $skipToken= ".",
    [Parameter(Mandatory=$false)]
    [string] $OutFolder = ".\UnrenameExpiredClasses",
    [Parameter(Mandatory=$false)]
    [string] $downloadFcns = "y",
    [Parameter(Mandatory=$true)]
    [string] $SectionsToUpdateFilePath,
    [Parameter(Mandatory=$true)]
    [string] $SDSExpiredPrefix
)

$GraphEndpointProd = "https://graph.microsoft.com"
$GraphEndpointPPE = "https://graph.microsoft-ppe.com"

$logFilePath = "$OutFolder\Revert-Expired-Classes.log"
$targetGroups = Import-Csv $SectionsToUpdateFilePath

#checking parameter to download common.ps1 file for required common functions
if ($downloadFcns -ieq "y" -or $downloadFcns -ieq "yes"){
    # Downloading file with latest common functions
    try {
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/OfficeDev/O365-EDU-Tools/master/SDS%20Scripts/common.ps1" -OutFile ".\common.ps1" -ErrorAction Stop -Verbose
        "Grabbed 'common.ps1' to current directory"
    } 
    catch {
        throw "Unable to download common.ps1"
    }
}
    
#import file with common functions
. .\common.ps1 

function Get-PrerequisiteHelp
{
    Write-Output @"
========================
 Required Prerequisites
========================

1. Install Microsoft Graph Powershell Module with command 'Install-Module Microsoft.Graph'

2.  Make sure to download common.ps1 to the same folder of the script which has common functions needed.  https://github.com/OfficeDev/O365-EDU-Tools/blob/master/SDS%20Scripts/common.ps1

3. Check that you can connect to your tenant directory from the PowerShell module to make sure everything is set up correctly.

    a. Open a separate PowerShell session
    
    b. Execute: "connect-graph -scopes Group.ReadWrite.All" to bring up a sign in UI. 
    
    c. Sign in with any tenant administrator credentials
    
    d. If you are returned to the PowerShell session without error, you are correctly set up

5. Retry this script.  If you still get an error about failing to load the Microsoft Graph module, troubleshoot why "Import-Module Microsoft.Graph.Authentication -MinimumVersion 0.9.1" isn't working

(END)
========================
"@
}
function Update-UnexpireSingleGroup($groupId, $logFilePath, $team) {

    $updateResultsFilePath = "$OutFolder\unrenameSectionResults.csv"

    $unexpiredDisplayName = $team.Name -replace $SDSExpiredPrefix
    $unexpiredSectionId = $team.SectionId -replace $SDSExpiredPrefix
    $unexpiredAnchorId = $team.SectionId -replace $SDSExpiredPrefix
    $unexpiredMailNickname = $team.SectionId -replace $SDSExpiredPrefix

    $uri = "https://graph.microsoft.com/beta/groups/$groupId"
    $requestBody = '{
        "displayName": "' + $unexpiredDisplayName + '",
        "extension_fe2174665583431c953114ff7268b7b3_Education_SyncSource_SectionId": "' + $unexpiredSectionId + '",
        "extension_fe2174665583431c953114ff7268b7b3_Education_AnchorId": "' + $unexpiredAnchorId + '",
        "mailNickname": "' + $unexpiredMailNickname + '",
        "extension_fe2174665583431c953114ff7268b7b3_Education_Status" : "Active"
    }'

    #Force encoding of utf8 as it gets changed for non-English language characters
    $requestBodyEncoded = ([System.Text.Encoding]::UTF8.GetBytes($requestBody))

    $result = Invoke-GraphRequest -Method Patch -Uri $uri -body $requestBodyEncoded -ContentType "application/json" -SkipHttpErrorCheck

    if ([string]::IsNullOrEmpty($_.Exception.Message) -eq $true ) {
        $statusMessage = "success"
    }
    else {
        $statusMessage = "fail"
    }

    #append to resultsfile
    $message = [string]::Format("{0},{1},{2},{3}", $team.Name, $unexpiredDisplayName, $team.SectionId, $statusMessage)
    $message | Out-File $updateResultsFilePath -Encoding utf8 -Append
}

function Update-UnexpireAllGroupsLoaded($incomingToken, $graphscopes, $targetGroups, $logFilePath) {
    $i = 0
    $processedTeams = @()
    
    $saveToken = $incomingToken

    $updateResultsFilePath = "$OutFolder\unrenameSectionResults.csv"

    # Setup update results csv
    "Old Section Name,New Section Name,SIS Id,Update Status" | Out-File $updateResultsFilePath -Encoding utf8

    ForEach ($team in $targetGroups) {
        $saveToken = Refresh-Token $saveToken $graphscopes
        Write-Progress "Processing teams..." -Status "Progress" -PercentComplete (($i / $targetGroups.count) * 100)
        Write-Output "Processing team $($team.Name)" | Out-File $logFilePath -Append
        try {
            Update-UnexpireSingleGroup $team.GraphId $logFilePath $team
        }
        catch {
            Write-Output "Error processing team $($team.Name)" | Out-File $logFilePath -Append
            $team.GraphId | Out-File $logFilePath -Append
            Write-Output ($_.Exception) | Format-List -force | Out-File $logFilePath -Append
        }
        $processedTeams = [array]$processedTeams + [array]$team

        $i ++
    }

    return $processedTeams
}
function Unretire-Sections($graphscopes, $targetGroups, $logFilePath) {
    $processedTeams = $null

    $initialToken = Initialize $graphscopes

    Write-Host "Attempting to Unexpire uploaded classes. Please wait..."
    Write-Output "Attempting to Unexpire uploaded classes. Please wait..." | out-file $logFilePath -append

    $processedTeams = Update-UnexpireAllGroupsLoaded $initialToken $graphscopes $targetGroups $logFilePath

    Write-Output "Script Complete." | Out-File $logFilePath -Append
    Write-Host "Script Complete."
}

# Main
$graphEndPoint = $GraphEndpointProd

if ($PPE)
{
    $graphEndPoint = $GraphEndpointPPE
}

#list used to request access to data
$graphscopes = "Group.ReadWrite.All"

try
{
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 0.9.1 | Out-Null
}
catch
{
    Write-Error "Failed to load Microsoft Graph PowerShell Module."
    Get-PrerequisiteHelp | Out-String | Write-Error
    throw
}

# Create output folder if it does not exist
if ((Test-Path $OutFolder) -eq 0)
{
    mkdir $OutFolder;
}

try {
    Unretire-Sections $graphscopes $targetGroups $logFilePath
}
catch {
    Write-Error "Terminal Error occurred in processing."
    write-error $_
    Write-output "Terminal error: exception: $($_.Exception)" | out-file $logFilePath -append
}

Write-Output "Please run 'disconnect-graph' if you are finished making changes."
