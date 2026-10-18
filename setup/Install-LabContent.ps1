<#
.SYNOPSIS
    Installs the LAB723 lab content into a running LAB723 lab: the lab files, the model, and the six images.

.DESCRIPTION
    Run it in the lab VM, in PowerShell as administrator, after the LAB723 begin state finishes:

        git clone https://github.com/bbenz/ai-lab C:\LabSetup\ai-lab
        Set-ExecutionPolicy Bypass -Scope Process -Force
        C:\LabSetup\ai-lab\setup\Install-LabContent.ps1

    It does what the event's VM image and life cycle actions (LCAs) do, so that you can test the lab steps:

    1. Copies labfiles to C:\LabFiles\LAB723, where the lab steps expect the manifests.
    2. Downloads the model to C:\LabFiles\LAB723-model, and checks each file's SHA-256 hash.
    3. Puts the six images in the lab's container registry. It imports them from GitHub Container Registry, where this
       repository's workflow publishes them, and builds the ones that aren't published there with az acr build.
    4. Removes the Ray cluster if it runs another image, and then runs the begin state again. That deploys lab-client,
       loadgen, the notebook, and the Ray cluster, uploads the model, renders the lab files, and runs the readiness gate.

    With -FilesOnly, it does only steps 1 and 2. Use that when you build the lab VM image.

.PARAMETER ImageSource
    Auto (default): import each image from SourceRegistry, and build the rest with az acr build.
    Import: import only. Build: build every missing image with az acr build.

.PARAMETER SourceRegistry
    Where the published images are, as <registry>/<owner>. The default is ghcr.io/<owner of this clone's GitHub origin>.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Import', 'Build')]
    [string]$ImageSource = 'Auto',
    [string]$SourceRegistry = '',
    [string]$ImageTag = '1.0.0',
    [string]$LabRoot = 'C:\LabFiles\LAB723',
    [string]$ModelPath = 'C:\LabFiles\LAB723-model',
    [switch]$FilesOnly,
    [switch]$SkipBeginState
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo = Split-Path -Parent $PSScriptRoot
$ImageNames = 'inference', 'inference-gpu', 'lab-client', 'loadgen', 'ray', 'notebook'
$StatePath = 'C:\ProgramData\LAB723-lca\state-prepare.json'
$BeginState = 'C:\LabSetup\LAB723-begin-state.ps1'

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Detail([string]$Text) { Write-Host "    $Text" }

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Az {
    # Runs the Azure CLI and returns its exit code. The error text is kept in $script:AzError.
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'  # Windows PowerShell turns a native command's error output into exceptions
    $output = & az @Arguments --only-show-errors 2>&1
    $code = $LASTEXITCODE
    $script:AzError = if ($code -ne 0) { ((@($output) | ForEach-Object { "$_" }) -join ' ').Trim() } else { '' }
    return $code
}

function Get-DefaultSourceRegistry {
    $ErrorActionPreference = 'Continue'
    $origin = [string](& git -C $Repo config --get remote.origin.url 2>$null)
    $match = [regex]::Match($origin, 'github\.com[:/]([^/]+)/')
    if ($match.Success) { return 'ghcr.io/' + $match.Groups[1].Value.ToLowerInvariant() }
    return ''
}

function Copy-LabFiles {
    Write-Step "Lab files to $LabRoot"
    New-Item -ItemType Directory -Force -Path $LabRoot | Out-Null
    Copy-Item -Path (Join-Path $Repo 'labfiles\*') -Destination $LabRoot -Recurse -Force
    $count = @(Get-ChildItem -LiteralPath $LabRoot -Recurse -File -Filter '*.yaml').Count
    Write-Detail "Copied. $LabRoot has $count YAML files. The begin state replaces <registry> in them."
}

function Get-Model {
    Write-Step "Model files to $ModelPath"
    $manifest = Get-Content -LiteralPath (Join-Path $Repo 'model\model.json') -Raw | ConvertFrom-Json
    New-Item -ItemType Directory -Force -Path $ModelPath | Out-Null
    foreach ($file in $manifest.files) {
        $target = Join-Path $ModelPath $file.name
        $expected = ([string]$file.sha256).ToUpperInvariant()
        if ((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $expected) {
            Write-Detail "$($file.name): already present"
            continue
        }
        $partial = "$target.partial"
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe --fail --location --silent --show-error --retry 5 --retry-delay 5 --output $partial $file.url
            if ($LASTEXITCODE -ne 0) { throw "Couldn't download $($file.name) from $($file.url)." }
        } else {
            Invoke-WebRequest -Uri $file.url -OutFile $partial -UseBasicParsing
        }
        $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $partial -Force
            throw "$($file.name) has SHA-256 $actual, not $expected. Nothing was saved."
        }
        Move-Item -LiteralPath $partial -Destination $target -Force
        Write-Detail "$($file.name): downloaded $((Get-Item -LiteralPath $target).Length) bytes, SHA-256 checked"
    }
    Write-Detail "From $($manifest.source), revision $($manifest.revision), license $($manifest.license)"
}

function Get-LabState {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        throw "$StatePath doesn't exist. Run the LAB723 begin state first, and then run this script again."
    }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if (-not $state.lab.registryName) {
        throw "The begin state hasn't created the container registry yet. Check its log in C:\ProgramData\LAB723-lca."
    }
    return $state.lab
}

function Test-Image([string]$Registry, [string]$Name) {
    return (Invoke-Az @('acr', 'repository', 'show', '--name', $Registry, '--image', "lab723/${Name}:$ImageTag", '--output', 'none')) -eq 0
}

function Build-Images([string]$Registry, [string[]]$Names) {
    $az = (Get-Command az -CommandType Application | Select-Object -First 1).Source
    $logDir = Join-Path $env:TEMP 'lab723-image-builds'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-Detail "Building $($Names -join ', ') with ACR Tasks. That takes 10 to 15 minutes. Logs: $logDir"
    $builds = foreach ($name in $Names) {
        $arguments = @('acr', 'build', '--registry', $Registry, '--image', "lab723/${name}:$ImageTag", '--platform', 'linux/amd64',
                       '--file', "images/$name/Dockerfile", '--only-show-errors', '.')
        $process = Start-Process -FilePath $az -ArgumentList $arguments -WorkingDirectory $Repo -NoNewWindow -PassThru `
                                 -RedirectStandardOutput (Join-Path $logDir "$name.log") -RedirectStandardError (Join-Path $logDir "$name.err.log")
        $null = $process.Handle  # Windows PowerShell keeps the exit code only if the handle was read
        [pscustomobject]@{ Name = $name; Process = $process }
    }
    $started = Get-Date
    while (@($builds | Where-Object { -not $_.Process.HasExited }).Count -gt 0) {
        Start-Sleep -Seconds 30
        $running = @($builds | Where-Object { -not $_.Process.HasExited } | ForEach-Object Name)
        if ($running.Count) { Write-Detail ("{0:mm\:ss} still building: {1}" -f ((Get-Date) - $started), ($running -join ', ')) }
    }
    $failed = @(foreach ($build in $builds) {
        $build.Process.WaitForExit()
        if ($build.Process.ExitCode -ne 0) { $build.Name }
    })
    foreach ($name in $failed) {
        $errors = (Get-Content -LiteralPath (Join-Path $logDir "$name.err.log") -Raw -ErrorAction SilentlyContinue)
        Write-Host "    Build of $name failed. $(if ($errors) { ($errors.Trim() -split "`n" | Select-Object -Last 3) -join ' ' })" -ForegroundColor Yellow
    }
    return $failed
}

function Set-Images($Lab) {
    Write-Step "Images in $($Lab.registryLoginServer)"
    if ((Invoke-Az @('account', 'show', '--output', 'none')) -ne 0) {
        throw 'The Azure CLI isn''t signed in. Run az login, select your lab account, and run this script again.'
    }
    if (-not $SourceRegistry) { $script:SourceRegistry = Get-DefaultSourceRegistry }
    $toBuild = New-Object System.Collections.Generic.List[string]
    foreach ($name in $ImageNames) {
        if (Test-Image $Lab.registryName $name) { Write-Detail "lab723/${name}:${ImageTag}: already in the registry"; continue }
        if ($ImageSource -ne 'Build' -and $SourceRegistry) {
            $source = "$SourceRegistry/lab723/${name}:$ImageTag"
            if ((Invoke-Az @('acr', 'import', '--name', $Lab.registryName, '--source', $source, '--image', "lab723/${name}:$ImageTag",
                             '--force', '--output', 'none')) -eq 0) {
                Write-Detail "lab723/${name}:${ImageTag}: imported from $source"
                continue
            }
            $reason = if ($script:AzError) { $script:AzError.Substring(0, [Math]::Min(160, $script:AzError.Length)) } else { 'no details' }
            Write-Detail "lab723/${name}:${ImageTag}: couldn't import it from $source ($reason)"
        }
        if ($ImageSource -eq 'Import') { throw "lab723/${name}:$ImageTag isn't published in $SourceRegistry. Publish the images, or use -ImageSource Auto." }
        $toBuild.Add($name)
    }
    if ($toBuild.Count -gt 0) {
        $failed = @(Build-Images $Lab.registryName $toBuild.ToArray())
        if ($failed.Count -gt 0) {
            throw ("Couldn't build $($failed -join ', '). If the logs say that ACR Tasks isn't available in this subscription, " +
                   'publish the images with the repository''s workflow, and run this script again with -ImageSource Import.')
        }
    }
    $missing = @($ImageNames | Where-Object { -not (Test-Image $Lab.registryName $_) })
    if ($missing.Count -gt 0) { throw "These images still aren't in the registry: $($missing -join ', ')." }
    Write-Detail "All six images are in $($Lab.registryLoginServer) with tag $ImageTag."
}

function Reset-RayCluster($Lab) {
    # KubeRay doesn't replace running pods when the RayCluster's image changes, so the begin state creates it again.
    $ErrorActionPreference = 'Continue'
    $expected = "$($Lab.registryLoginServer)/lab723/ray:$ImageTag"
    $current = [string](& kubectl get raycluster ray-lab -n ray -o 'jsonpath={.spec.headGroupSpec.template.spec.containers[0].image}' 2>$null)
    if ($current -and $current -ne $expected) {
        Write-Step 'Ray cluster'
        Write-Detail "ray-lab runs $current. Removing it, so that the begin state creates it with $expected."
        & kubectl delete raycluster ray-lab -n ray --wait=true --timeout=5m | Out-Null
    }
}

if (-not (Test-Administrator)) { throw 'Run this script in PowerShell as administrator.' }
if (-not (Test-Path -LiteralPath (Join-Path $Repo 'labfiles'))) { throw "$Repo doesn't look like the ai-lab repository." }

Copy-LabFiles
Get-Model
if ($FilesOnly) {
    Write-Host "Done. The lab files are in $LabRoot, and the model is in $ModelPath." -ForegroundColor Green
    return
}

$lab = Get-LabState
Set-Images $lab
Reset-RayCluster $lab
if ($SkipBeginState) {
    Write-Host "Done. Run the begin state again to deploy the workloads: $BeginState" -ForegroundColor Green
    return
}
if (Test-Path -LiteralPath $BeginState) {
    Write-Step 'Begin state, again, to deploy the workloads with the new images'
    & $BeginState
} else {
    Write-Host ("Done. This lab wasn't built with the manual begin state, so run the prepare LCA again to deploy the " +
                'workloads, upload the model, and render the lab files.') -ForegroundColor Green
}
