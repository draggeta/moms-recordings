[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$ContainerName,

    [Parameter(Mandatory = $true)]
    [string]$Connection,

    [Parameter(Mandatory = $true)]
    [string]$SeriesName,

    [Parameter()]
    [int]$Runtime = 3600,

    [Parameter()]
    [string]$MediaType = "mp3",

    [Parameter()]
    [int]$KeepCount = 10,

    [Parameter(Mandatory = $true)]
    [uri]$EpisodeUri,

    [Parameter(Mandatory = $true)]
    [uri]$WebhookUri
)


class Series {
    # Class defining a Series information
    [string]$Name
    [uri]$Uri
    [int]$KeepCount = 10
    [Episode]$Episode

    # default constructor
    Series() {}

    # constructor
    Series([string]$Name, [uri]$Uri, [int]$KeepCount, [Episode]$Episode) {
        $this.Name = $Name
        $this.Uri = $Uri
        $this.KeepCount = $KeepCount
        $this.Episode = $Episode
    }

    # constructor
    Series([string]$Name, [uri]$Uri, [int]$KeepCount, [string]$EpisodeName, [string]$MediaType, [int]$Runtime) {
        $this.Name = $Name
        $this.Uri = $Uri
        $this.KeepCount = $KeepCount
        $this.Episode = [Episode]::New($EpisodeName, $MediaType, $Runtime)
    }
}


class Episode {
    # Class defining the roperties of an episode
    [string]$Name
    [string]$MediaType
    [string]$FileName
    [string]$FilePath
    [int]$Runtime

    # default constructor
    Episode() {}

    # constructor
    Episode([string]$Name, [string]$MediaType, [int]$Runtime) {
        $normalizedName = Remove-RadioDiacritics -String $Name
        $normalizedName = $normalizedName.ToLower()
        $normalizedName = $normalizedName -replace ' ', '_'
        $date = Get-Date -Format 'yyyy-MM-dd-HH-mm-ss'
        $normalizedMediaType = $MediaType.ToLower()

        $this.Name = $Name
        $this.MediaType = $MediaType.ToLower()
        $this.FileName = $normalizedName + '-' + $date + '.' + $normalizedMediaType
        $this.Runtime = $Runtime

    }
}


function Invoke-RadioRetryCommand {
    <#
    .SYNOPSIS
    Retries a command.

    .DESCRIPTION
    Retries a command that caused an error. This could be due to timeouts or something else. It is meant to add robustness in case of transient failures.

    .PARAMETER ScriptBlock
    The scriptblock you want to execute. Could be anything ranging from a single command to a whole script.

    .PARAMETER Retries
    The amount of times to retry the command. These are on top of the first execution.

    .PARAMETER Delay
    The initial between retries in seconds. Can be increased per run by specifying a value for the IncreasingBackOff parameter.

    .PARAMETER IncreasingBackOff
    The amount to increment the delay with per run, in seconds.

    .EXAMPLE
    PS C:\> Invoke-TssRetryCommand -ScriptBlock {
        Connect-AzureAd -TenantId $AzureADConnection.TenantId -ApplicationId $AzureADConnection.ApplicationId -CertificateThumbprint $AzureADConnection.CertificateThumbprint > $null
    } -Retries 5 -Delay 5 -IncreasingBackOff 1 -ErrorAction Stop

    Description
    -----------
    Tries to connect to Azure AD up to 6 times (5 retries plus initial try). Each time it fails, it waits 5 seconds incremented by 1 second each time it fails.

    .NOTES
    Quite useful for transient errors. Don't use this in the hopes that it fixes a hard error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [scriptBlock]$ScriptBlock,

        [Parameter()]
        [int]$Retries = 5,

        [Parameter()]
        [int]$Delay = 3,

        [Parameter()]
        [ValidateRange(0, 60)]
        [int]$IncreasingBackOff = 0
    )
    # Setting ErrorAction to Stop is important. This ensures any errors that occur in the command are
    # treated as terminating errors, and will be caught by the catch block.
    begin {
        $ErrorActionPreference = "Stop"
        $completed = $false
        $retrycount = 0
    }
    process {
        do {
            try {
                Invoke-Command -ScriptBlock $ScriptBlock
                Write-Verbose -Message "Command [$ScriptBlock] succeeded."
                $completed = $true
            } catch {
                # Throw the error only if there are no retries left.
                if ($retrycount -ge $Retries) {
                    Write-Verbose -Message "Command [$ScriptBlock] failed the maximum number of $retrycount time(s)."
                    throw
                }
                # If there are retries left, loop through the do while loop.
                else {
                    Write-Verbose -Message "Command [$ScriptBlock] failed $retrycount time(s). Retrying in $Delay seconds."
                    Start-Sleep -Seconds $Delay
                    $Delay = $Delay + $IncreasingBackOff
                    $retrycount++
                }
            }
        }
        while ($true -ne $completed)
    }
    end {}
}


function Remove-RadioDiacritics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$String
    )

    begin {}

    process {
        $normalized = $String.Normalize( [Text.NormalizationForm]::FormD )
        ($normalized -replace '\p{M}', '')
    }

    end {}
}


function Get-RadioEpisode {
    [CmdletBinding()]
    param (
        # A Series object
        [Parameter(Mandatory = $true)]
        [Series]$Series
    )

    begin {}

    process {
        # Start a PSJob so that the IWR cmdlet can be stopped after the wait
        Write-Verbose -Message "Download started at '$(get-date -Format o)'.`n"
        $job = Start-Job -ScriptBlock {
            param($Uri, $OutFile)
            # outputs the storage path
            Get-Location
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing > $null
        } -InitializationScript $exportFunction -ArgumentList $Series.Uri, $Series.Episode.FileName

        # Wait for the timeout and the stop the job after the timeout. This is
        # basically the time this script should record.
        Write-Verbose -Message "Waiting for $($Series.Episode.Runtime) second(s)`n"
        Wait-Job -Job $job -Timeout $Series.Episode.Runtime > $null
        Stop-Job -Job $job > $null
        Write-Verbose -Message "Download stopped at '$(get-date -Format o)'.`n"

        # Get the location and remove the job
        $location = Receive-Job -Job $job
        Remove-Job -Job $job > $null

        # Returns the path of the file as output
        $Series.Episode.FilePath = Join-Path -Path $location -ChildPath $Series.Episode.FileName

        $Series
    }

    end {}
}


function Set-RadioEpisodeBlobContent {
    [CmdletBinding()]
    param (
        # A Series object
        [Parameter(Mandatory = $true)]
        [Series]$Series,

        # Storage Account context
        [Parameter(Mandatory = $true)]
        [string]$Context,

        # Name of the Storage Account Container
        [Parameter(Mandatory = $true)]
        [string]$ContainerName
    )

    begin {}

    process {
        $StorageBlobContentParams = @{
            File      = $Series.Episode.FilePath
            Container = $ContainerName
            Blob      = $Series.Episode.FileName
            Context   = $ctx
            Force     = $true
        }
        Invoke-RadioRetryCommand -ScriptBlock {
            Write-Verbose -Message "Uploading '$($upload.Name)' to Azure Blob.`n"
            $upload = Set-AzStorageBlobContent @StorageBlobContentParams
            Write-Verbose -Message "Uploaded '$($upload.Name)' to Azure Blob.`n"
        }
    }

    end {}
}


function Invoke-RadioEpisodeFlow {
    [CmdletBinding()]
    param (
        # A Series object
        [Parameter(Mandatory = $true)]
        [Series]$Series,

        # URI of the stream to download
        [Parameter(Mandatory = $true)]
        [uri]$Uri,

        # Name of the Storage Account Container
        [Parameter(Mandatory = $true)]
        [string]$ContainerName
    )

    begin {
    }

    process {
        $body = @{
            container  = [System.Web.HttpUtility]::UrlEncode($ContainerName)
            fileName   = [System.Web.HttpUtility]::UrlEncode($Series.Episode.FileName)
            seriesName = [System.Web.HttpUtility]::UrlEncode($Series.Name)
        } | ConvertTo-Json

        Invoke-RadioRetryCommand -ScriptBlock {
            Write-Verbose -Message "Invoking webhook URI '$Uri'."
            Invoke-WebRequest -Uri $Uri -Method Post -ContentType "application/json" -Body $body -UseBasicParsing
            Write-Verbose -Message "Invoked webhook URI '$Uri'."
        }
    }

    end {
    }
}


function Clear-RadioEpisode {
    [CmdletBinding()]
    param (
        # A Series object
        [Parameter(Mandatory = $true)]
        [Series]$Series,

        # Storage Account context
        [Parameter(Mandatory = $true)]
        [string]$Context,

        # Name of the Storage Account Container
        [Parameter(Mandatory = $true)]
        [string]$ContainerName
    )

    begin {}

    process {
        # Remove any old files that exceed the number of episodes to keep.
        Invoke-RadioRetryCommand -ScriptBlock {
            Write-Verbose -Message "Retrieving list of files to delete.`n"
            $listFiles = Get-AzStorageBlob -Container $ContainerName -Context $ctx |
                Sort-Object -Property LastModified -Descending |
                Select-Object -Skip $Series.KeepCount

            Write-Verbose -Message "Removing files.`n"
            $listFiles | Remove-AzStorageBlob
            Write-Verbose -Message "Removed the following files:`n$($listFiles.Name | Out-String)`n"
        }
    }

    end {}
}


$series = [Series]::New($SeriesName, $EpisodeUri, $KeepCount, $SeriesName, $MediaType, $Runtime)

# Connect to Azure
$credentials = Get-AutomationConnection -Name $Connection
Write-Verbose -Message "Connecting to Azure"
Connect-AzAccount -ServicePrincipal -Tenant $credentials.TenantID -ApplicationId $credentials.ApplicationID -CertificateThumbprint $credentials.CertificateThumbprint

# Connect to the storage account
$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$ctx = $storageAccount.Context
Write-Verbose -Message "Storage account context:`n$ctx`n"

$series = Get-RadioEpisode -Series $series

Set-RadioEpisodeBlobContent -Series $series -Context $ctx -ContainerName $ContainerName

Invoke-RadioEpisodeFlow -Series $series -Uri $WebhookUri -ContainerName $ContainerName

Clear-RadioEpisode -Series $series -Context $ctx -ContainerName $ContainerName