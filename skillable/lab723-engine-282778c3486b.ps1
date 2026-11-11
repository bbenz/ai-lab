<#
.SYNOPSIS
    LAB723 configure engine: configures the attendee's Azure environment, which the LAB723
    resource template deploys, and the lab VM, as the cloud subscription's service principal.

.DESCRIPTION
    Skillable asks for life cycle action (LCA) scripts of 200 lines or less, so the LCA that runs
    this script, "LAB723 LCA - configure lab environment with credentials.ps1", is short. It takes
    this script from the VM image, if the image has it, or downloads it from the lab's public
    GitHub repository. It runs it only if its SHA-256 hash is the one that "LAB723 resource
    template - build.ps1" gave it, and passes it the cloud subscription pool's tokens and its
    settings, which replace the defaults below. The short LCA's settings in Skillable:

      Action: Execute Script in Virtual Machine    Language: PowerShell
      Event: First Displayable                     Blocking: Yes    Delay: 60 seconds
      Timeout: 60 minutes                          Retries: 2
      Error action: End lab (event) or Log (testing)

    Where Skillable allows a longer script, you can paste this whole script into that life cycle
    action instead. "LAB723 resource template - Skillable setup.md" in this folder has the details.

    Skillable deploys the lab's Azure resources from the LAB723 resource template, "LAB723 resource
    template.json" in this folder, which the lab profile attaches to the resource group, before
    this action runs. This action deploys no Azure resources, other than role assignments that the
    template can't make. It finds the template's deployment in the resource group, reads its
    outputs, and configures what a template can't: the subscription's resource providers, the lab
    content, the portal user's roles, the cluster, and the lab VM.

    It signs in as the cloud subscription's service principal, the identity that Skillable supplies
    to scripts, with the cloud subscription pool's four secure tokens, from the short LCA's CLOUD
    CREDENTIALS section, or from the one below this header when you paste this whole script.
    Skillable lets only a pool admin save a script that has them, so they're commented out there,
    with a space after each @, and a lab developer can save the script as it is. A pool admin, such
    as SkillableEventSupport, then turns them on, as that section describes, and saves the script.
    After that, only a pool admin can save it, so change the settings before you ask one.

    The attendee never gets the service principal: this script doesn't sign in the lab user's Azure
    CLI, and the readiness gate LCA removes the service principal's sign-in from the VM before the
    attendee gets it. Windows PowerShell writes the text of a script that it considers suspicious,
    such as this one, to its event log (event 4104), with the token values that Skillable puts in
    it, the secret included. So the readiness gate LCA clears the PowerShell event logs too. The
    attendee signs in to the Azure CLI with their own lab account.

    It builds the launch state described in sections 4 through 9 of "LAB723 Skillable
    prerequisites and launch state.md":

      Content  The lab content repository (ContentRepoUrl) at the ContentVersion tag, cloned
               from GitHub: the lab files and the model's download list. Its workflow publishes
               the six lab images for that tag to SourceRegistry. The resource template has its
               own copy of the repository's dashboard.
      Azure    Resource providers and the ManagedGPUExperiencePreview feature. Then it waits for
               the resource template's deployment, if it's still running, and reads its outputs.
               The template deploys Log Analytics and Azure Monitor workspaces with Managed
               Prometheus and Container insights, Application Insights, a container registry, a
               storage account with the model container, a user-assigned managed identity with a
               federated credential, an AKS Automatic cluster, the LAB723-AI-inference dashboard
               with Grafana, and role assignments. Then the lab images are imported into the
               registry, and the model files are downloaded and uploaded.
      Access   AKS RBAC Cluster Admin for the lab's service principal and the portal user;
               Monitoring Data Reader and Log Analytics Reader for the portal user; AcrPull for
               the kubelet identity; Storage Blob Data Reader for the workload identity. The
               template assigns the roles that it can. A template can't look up the portal user's
               object ID, so this action assigns the portal user's roles. It also makes sure that
               the service principal has its roles, in case Skillable deployed the template as
               another identity.
      Cluster  Namespaces ai-lab and ray; the gpu NodePool and its managed GPU AKSNodeClass; the
               inference ServiceAccount, lab-environment ConfigMap, and appinsights Secret; a
               ServiceMonitor; KubeRay, with three tries; the lab-notebook, lab-client, and loadgen
               (0 replicas) deployments; the ray-lab RayCluster, once KubeRay is deployed; image
               pre-pulling; a workload identity check; 3.5 to 5 spare CPUs on the lab nodes, which
               the capacity reserve in lab723-capacity holds to, or one more node provides
      Lab VM   A kubeconfig in the lab user's profile, in kubelogin azurecli mode, and the lab
               user's Azure CLI set up for browser sign-in, which reuses the attendee's Azure
               portal sign-in in Edge; the lab files from the content repository, with the
               registry and storage names rendered into them; VS Code shortcuts that open the
               lab folder, because the image's VS Code doesn't restore windows

    Then it runs the readiness gate from section 11 of the prerequisites. A run with failed
    checks or skipped steps is recorded as incomplete, and runs again in full the next time.

    Long steps, such as creating the cluster, run in a background worker (a scheduled task that
    runs as SYSTEM), so a Skillable timeout can't interrupt them. A retry waits for the same
    worker instead of starting another one. Logs and state are in C:\ProgramData\LAB723-lca. The
    worker's own Azure CLI profile is in its azure-cli folder, which the lab user can't open. A copy
    of each run's log, which ends with a summary and the total elapsed time, goes to 09-setup in the
    lab folder, so that a proctor can review the setup in VS Code if something goes wrong during the
    lab. The final confirmation also shows the total elapsed time.

    A kubectl or Helm command that fails with an error from the cluster that usually passes, such
    as InternalError when the cluster's Azure RBAC authorization webhook is slow, gets up to five
    tries. The log shows each retry.

    Set $Mode to 'Verify' to run only the readiness gate, or use
    "LAB723 LCA - readiness gate.ps1". Either way, the readiness gate then removes the cloud
    credentials from the VM, unless RemoveCredentials is Never.

    To build the same begin state by hand, for example to test the lab steps before a pool admin
    turns on the cloud credentials, set Manual to $true, and run this script in the lab VM in
    PowerShell as administrator. It then signs in to the Azure CLI as you, the lab's cloud portal
    user, instead of the service principal, and runs in that window so you can follow it. If the
    resource group has no LAB723 resource template deployment, for example because the test lab
    profile doesn't attach the template, it deploys the copy of the template that's embedded
    below, as you. "LAB723 configure lab - manual bootstrap.txt" does this for you. Your lab
    account needs the Owner role on the resource group, which a test profile can give it:
    "LAB723 resource template - Skillable setup.md" has the details.
#>

# =============================================================================================
# CLOUD CREDENTIALS, for a cloud subscription pool admin, such as SkillableEventSupport
#
# This script configures the lab's Azure resources as the cloud subscription's service principal,
# so it needs the pool's four secure tokens, on the four lines inside @{ } below. They're
# commented out, and each token has a space after its @, so that a lab developer, who can't
# save a script with the pool's secure tokens, can save this one.
#
# To turn them on, a pool admin changes only those four lines:
#   1. Delete the # at the start of each line.
#   2. Delete the space between the @ and lab in each line.
#   3. Save the script.
#
# Until then, this life cycle action stops at once, with a message that points here. A manual
# run (Manual = $true in the settings below) uses your own Azure CLI sign-in instead. When the
# short LCA runs this script, it passes its own tokens, and this section stays as it is.
# =============================================================================================
$CloudSubscription = @{
    # TenantId       = '@ lab.CloudSubscription.TenantId'
    # SubscriptionId = '@ lab.CloudSubscription.Id'
    # ClientId       = '@ lab.CloudSubscription.AppId'
    # ClientSecret   = '@ lab.CloudSubscription.AppSecret'
}
# The short LCA passes the pool's tokens in $LAB723Credentials.
if ($LAB723Credentials -is [Collections.IDictionary]) { $CloudSubscription = $LAB723Credentials }

# =============================================================================================
# Settings. Skillable replaces each token before the script runs. Change ResourceGroup1 and
# User1 to the names in your lab profile. Make your changes before a pool admin turns on the
# cloud credentials above: after that, only a pool admin can save this script. When the short
# LCA runs this script, the settings in the short LCA replace these defaults. Skillable replaces
# tokens only in the short LCA, so it has the ResourceGroup and PortalUser settings.
# =============================================================================================
$Mode = 'Prepare'   # Prepare: build the environment, then run the readiness gate. Verify: gate only.

$Settings = [ordered]@{
    ResourceGroup        = '@lab.CloudResourceGroup(ResourceGroup1).Name'
    PortalUser           = '@lab.CloudPortalCredential(User1).Username'    # Empty: the only user with a role on the resource group

    # The cloud subscription and its service principal, from the CLOUD CREDENTIALS section above
    TenantId             = [string]$CloudSubscription.TenantId
    SubscriptionId       = [string]$CloudSubscription.SubscriptionId
    ClientId             = [string]$CloudSubscription.ClientId
    ClientSecret         = [string]$CloudSubscription.ClientSecret
    RemoveCredentials    = 'AfterGate'               # AfterGate: the readiness gate LCA removes the service principal's
                                                     # sign-in from the VM, and clears the PowerShell event logs.
                                                     # AfterPrepare: for a profile without that LCA. Never: testing only.

    # Environment
    Location             = ''                        # For a manual run's template deployment. Empty: the resource group's region
    KubernetesVersion    = '1.36'                    # For a manual run's template deployment. Within one minor version of kubectl.
    GpuVmSize            = 'Standard_NC4as_T4_v3'    # The reserved GPU size
    GpuCpuLimit          = '8'                       # Caps the gpu NodePool at two 4-vCPU GPU nodes
    PatchDefaultNodePool = $true                     # WhenEmpty consolidation, so NAP doesn't move lab pods
    CpuVmSizes           = 'Standard_D4as_v5,Standard_D4s_v5,Standard_D4as_v6'
                                                     # The only VM sizes for NAP's CPU nodes, in the default NodePool: 4 vCPUs
                                                     # and 16 GiB. The subscription pool's access control policy must allow
                                                     # each one, and the lab subscriptions need quota for them. Empty: any
                                                     # D-family size
    WarmCapacity         = $true                     # Keep 3.5 to 5 spare CPUs on the lab nodes for Exercises 2 to 4

    # Lab content: the lab files and the model's download list come from this public repository at the ContentVersion
    # tag. Its workflow publishes the six lab images for the tag to SourceRegistry.
    ContentRepoUrl       = 'https://github.com/bbenz/ai-lab'
    ContentVersion       = 'v1.0.0'                  # A tag in ContentRepoUrl

    # Images: <registry>/lab723/<name>:<ImageTag>. Missing images are imported from SourceRegistry, if set.
    ImageTag             = ''                        # Empty: ContentVersion without the v, for example 1.0.0
    SourceRegistry       = 'ghcr.io/bbenz'           # Where the content repository's workflow publishes public images
    SourceUsername       = ''                        # Only for a source registry that needs credentials: use a pull-only token
    SourcePassword       = ''
    RayVersion           = '2.59.0'
    RayFallbackImage     = 'docker.io/rayproject/ray:2.59.0-py312-cpu'   # Used if lab723/ray can't be imported
    RayWorkers           = 2
    KubeRayChartVersion  = '1.7.1'
    SmokeTestImage       = 'mcr.microsoft.com/azure-cli:2.91.0'

    # Lab files, model, and dashboard
    LabRoot              = 'C:\LabFiles\LAB723'
    LabFilesZipUrl       = ''                        # Optional .zip of lab files to use instead of the content repository's
    ModelSourcePath      = 'C:\LabFiles\LAB723-model'    # Downloaded as model\model.json lists, then uploaded to the container
    ModelContainer       = 'models'                  # For a manual run. A deployed template's name wins.
    DashboardName        = 'LAB723-AI-inference'     # For a manual run, and the readiness gate. A deployed template's name wins.
    DashboardApiVersion  = '2026-09-01'              # Must support dashboards and dashboards/dashboardDefinitions

    # The resource template's deployment, which Skillable runs before this action
    TemplateDeployment   = ''                        # Empty: the newest deployment in the resource group with the template's outputs
    TemplateWaitMinutes  = 30                        # How long to wait for a template deployment that's still running

    # Behavior
    LabUser              = ''                        # Empty: the user who is signed in to Windows
    WaitMinutes          = 50                        # How long this action waits for the worker. Keep it 10 below the LCA's Timeout.
    GateFailsPrepare     = $false                    # $true for the event: a failed readiness gate fails this action
    Manual               = $false                    # $true: you run this script by hand, signed in as the portal user. See the header.
}
# The short LCA passes its settings in $LAB723Overrides. Each one replaces the default above.
if ($LAB723Overrides -is [Collections.IDictionary]) {
    foreach ($key in @($LAB723Overrides.Keys)) {
        if (-not $Settings.Contains($key)) { throw "LAB723 configure can't start: the short LCA has an unknown setting, $key." }
        $Settings[$key] = $LAB723Overrides[$key]
    }
}

# =============================================================================================
# Worker. The launcher at the end of this script saves this block as
# C:\ProgramData\LAB723-lca\lab723-lca-worker.ps1 and runs it.
# =============================================================================================
$Worker = {
param(
    [ValidateSet('Prepare', 'Verify')]
    [string]$Mode = 'Prepare',
    [string]$ConfigPath = 'C:\ProgramData\LAB723-lca\config.json',
    [string]$RunId = '',
    [string]$LaunchedAt = ''   # When the LCA script or the manual bootstrap started, for the total elapsed time
)
# LAB723 LCA worker. The LCA script writes this file. Change the LCA script, not this copy.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$Cfg            = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Manual         = [bool]$Cfg.Manual   # Run by hand in the lab VM, as the signed-in Azure CLI user
if (-not $Cfg.ImageTag) { $Cfg.ImageTag = ([string]$Cfg.ContentVersion) -replace '^v', '' }   # The workflow's tag for v1.0.0 is 1.0.0
# Keep secrets in memory only. Verify mode and later runs don't need them on disk.
if ($Cfg.ClientSecret -or $Cfg.SourcePassword) {
    $onDisk = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $onDisk.ClientSecret = ''
    $onDisk.SourcePassword = ''
    [IO.File]::WriteAllText($ConfigPath, (ConvertTo-Json -InputObject $onDisk -Depth 3), (New-Object Text.UTF8Encoding($false)))
}
$LcaDir         = Split-Path -Parent $ConfigPath
$StatePath      = Join-Path $LcaDir ('state-{0}.json' -f $Mode.ToLowerInvariant())
$Manifests      = Join-Path $LcaDir 'manifests'
$RunStamp       = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$LogPath        = Join-Path $LcaDir ('{0}-{1}.log' -f $Mode.ToLowerInvariant(), $RunStamp)
$Utf8           = New-Object Text.UTF8Encoding($false)
$Steps          = New-Object System.Collections.Generic.List[object]
$Checks         = New-Object System.Collections.Generic.List[object]
$Lab            = [ordered]@{}   # Names and IDs shared by the steps, the readiness gate, and lab variables
$Images         = [ordered]@{}
$StartedAt      = (Get-Date).ToString('o')
# The total elapsed time counts from when the LCA script or the manual bootstrap started the run.
$RunStart       = [DateTimeOffset]::Now
if ($LaunchedAt) { try { $RunStart = [DateTimeOffset]::Parse($LaunchedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
# A copy of the log in the lab folder, which ends with a summary, so that a proctor can review the setup in VS Code if
# something goes wrong during the lab. A problem with the copy never stops the run.
$SetupLogPath   = ''
try {
    $setupDir = Join-Path ([string]$Cfg.LabRoot) '09-setup'
    New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
    $SetupLogPath = Join-Path $setupDir ('{0}-{1}.log' -f $(if ($Mode -eq 'Verify') { 'readiness-gate' } else { 'begin-state' }), $RunStamp)
    $header = ('{0}, {1}, started {2:yyyy-MM-dd HH:mm:ss}. The setup''s activity, with a summary at the end.' -f
               $(if ($Mode -eq 'Verify') { 'LAB723 readiness gate' } else { 'LAB723 begin state' }),
               $(if ($Manual) { 'manual run' } else { 'life cycle action' }), $RunStart.LocalDateTime)
    [IO.File]::WriteAllText($SetupLogPath, "$header`r`nMore detail: $LcaDir`r`n`r`n", $Utf8)
} catch {
    $SetupLogPath = ''
}
$RG             = [string]$Cfg.ResourceGroup
$LabAzureDir    = Join-Path $Cfg.LabProfile '.azure'     # The lab user's Azure CLI profile, which the attendee signs in
# The worker's own Azure CLI profile, signed in as the service principal. A manual run uses your own sign-in instead.
$AzureConfigDir = if ($Manual) { $LabAzureDir } else { Join-Path $LcaDir 'azure-cli' }
$Kubeconfig     = Join-Path $Cfg.LabProfile '.kube\config'
$AzPython       = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\python.exe'
$K8sDir         = 'C:\Program Files\Kubernetes'
$KubectlExe     = Join-Path $K8sDir 'kubectl.exe'
$KubeloginExe   = Join-Path $K8sDir 'kubelogin.exe'
$HelmExe        = Join-Path $K8sDir 'helm.exe'
$CodeExe        = 'C:\Program Files\Microsoft VS Code\Code.exe'
$CommonPrograms = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$PublicDesktop  = if ($env:PUBLIC) { Join-Path $env:PUBLIC 'Desktop' } else { 'C:\Users\Public\Desktop' }
$TemplatePath   = Join-Path $LcaDir 'lab723-resource-template.json'   # A manual run's copy of the embedded resource template
$TemplateMarker = 'lab723_template_version'   # The output that marks a deployment of the LAB723 resource template
$ContentDir     = ''   # The lab content repository, once the Lab content step has downloaded it
# Where the lab steps expect their files: what they open, apply, and patch in LabRoot, the checkpoint folders that their
# Stuck? sections apply, and the notebooks that Exercise 5 opens from the notebook server's root folder.
$LabStepFiles   = '02-deploy\inference-deployment.yaml', '02-deploy\inference-service.yaml', '02-deploy\inference-ingress.yaml',
                  '02-deploy\guardrails\no-resources.yaml', '03-optimize\inference-gpu.yaml', '03-optimize\profiles\undersized.yaml',
                  '03-optimize\profiles\balanced.yaml', '03-optimize\profiles\large.yaml', '04-scale\hpa.yaml'
$LabStepFolders = 'checkpoints\ex3', 'checkpoints\ex4', 'checkpoints\ex5'
$LabNotebooks   = 'ray-batch-inference.ipynb', 'ray-batch-inference-EXAMPLE-OUTPUT.ipynb'
$Placeholders   = '<registry>', '<storage-account>', '<model-container>', '<workload-identity-client-id>'
# The spare capacity that the lab nodes need when the lab opens, in CPUs and GiB. Exercises 2 and 3 need about 3.5 CPUs,
# with 2 CPUs and 4 GiB on one node, so that the large profile never waits for a node. Exercise 4's peak needs 5 more CPUs
# (four 1-CPU inference pods and two 500m loadgen pods), so less than 5 makes NAP add a node while attendees watch.
# NAP chooses the nodes' VM sizes, so the Warm capacity step reserves the extra CPU or has NAP add a node.
$Warm           = [pscustomobject]@{ MinCpu = 3.5; MaxCpu = 5.0; AimCpu = 4.25; LargeCpu = 2.0; LargeGiB = 4.0 }
$CapacityNs     = 'lab723-capacity'   # The capacity reserve's namespace
# NAP's default NodePool allows any D-family size, but the subscription pool's access control policy allows only some. When
# NAP picks one that the policy denies, the VM fails with RequestDisallowedByPolicy, NAP tries again, and the pod waits for a
# node that never comes. So Set-NodePools limits the default NodePool to CpuVmSizes, with the first key below.
$CpuVmSizes     = @(([string]$Cfg.CpuVmSizes) -split '[\s,;]+' | Where-Object { $_ })
$SizeKeys       = 'node.kubernetes.io/instance-type', 'karpenter.azure.com/sku-name'   # NodePool requirement keys that name sizes
# The GrafanaDashboardResourceType tag value that the docs give for a dashboard saved from an AKS cluster. The cluster's
# Saved dashboards tab, on its Dashboards with Grafana page, lists only dashboards with a matching value.
$AksDashboardType = 'microsoft.ContainerService/managedClusters'
# Errors from the cluster that usually pass. On a new cluster, the Azure RBAC authorization webhook (guard) sometimes takes
# longer than the API server's 3-second limit, and the API server then refuses the request with InternalError, without
# doing it. A kubectl or Helm command whose own error, its last line, matches gets up to four more tries, 10, 20, 30, and
# 40 seconds apart. A run waits at most BudgetSeconds in all for them, so that a cluster that stays unreachable can't hold
# the run until its timeout.
$KubeTransient  = '(?i)' + (('InternalError', 'ServiceUnavailable', 'TooManyRequests', '\((Timeout|Unauthorized)\)',
                             'an error on the server', 'Internal Server Error', 'Client\.Timeout exceeded',
                             'context deadline exceeded', 'i/o timeout', 'TLS handshake timeout', 'connection refused',
                             'connection to the server .* was refused', 'connection reset by peer', 'unexpected EOF',
                             'http2: client connection lost', 'Unable to connect to the server', 'Kubernetes cluster unreachable',
                             'the server is currently unable to handle the request', 'etcdserver: (request timed out|leader changed)',
                             'failed calling webhook', 'failed to call webhook', 'net/http: request canceled',
                             'watch closed before') -join '|')
$TransientRetry = [pscustomobject]@{ Attempts = 5; DelaySeconds = 10; BudgetSeconds = 600; Spent = 0; Exhausted = $false }
# Runs in the notebook pod, and lists the notebook server's root folder through its API.
$NotebookListCode = "import json, urllib.request; print(chr(10).join(i['name'] for i in json.load(urllib.request.urlopen('http://127.0.0.1:8888/api/contents'))['content']))"
$SpObjectId     = ''
$AppInsightsConnection = ''
$CredentialsRemoved    = $false
$ProviderNamespaces = 'Microsoft.ContainerService', 'Microsoft.ContainerRegistry', 'Microsoft.Compute', 'Microsoft.Network',
                      'Microsoft.Storage', 'Microsoft.ManagedIdentity', 'Microsoft.OperationalInsights', 'Microsoft.Insights',
                      'Microsoft.Monitor', 'Microsoft.AlertsManagement', 'Microsoft.Dashboard', 'Microsoft.PolicyInsights'
# Regions where AKS Automatic is generally available, from the AKS documentation in October 2026, and the closest of
# them to some regions that don't have it. An explicit Location setting skips this check.
$AutomaticRegions = 'australiaeast', 'austriaeast', 'belgiumcentral', 'brazilsouth', 'canadacentral', 'centralindia', 'centralus',
                    'chilecentral', 'denmarkeast', 'eastasia', 'eastus', 'eastus2', 'francecentral', 'germanywestcentral',
                    'indonesiacentral', 'israelcentral', 'italynorth', 'japaneast', 'japanwest', 'koreacentral', 'malaysiawest',
                    'mexicocentral', 'newzealandnorth', 'northeurope', 'norwayeast', 'polandcentral', 'southafricanorth',
                    'southcentralus', 'southeastasia', 'spaincentral', 'swedencentral', 'switzerlandnorth', 'uaenorth', 'uksouth',
                    'westeurope', 'westus2', 'westus3'
$NearbyAutomaticRegion = @{
    australiacentral = 'australiaeast'; australiacentral2 = 'australiaeast'; australiasoutheast = 'australiaeast'
    westus = 'westus2'; westcentralus = 'westus2'; northcentralus = 'centralus'; canadaeast = 'canadacentral'
    brazilsoutheast = 'brazilsouth'; ukwest = 'uksouth'; francesouth = 'francecentral'; germanynorth = 'germanywestcentral'
    norwaywest = 'norwayeast'; switzerlandwest = 'switzerlandnorth'; southindia = 'centralindia'; westindia = 'centralindia'
    koreasouth = 'koreacentral'; uaecentral = 'uaenorth'; southafricawest = 'southafricanorth'; swedensouth = 'swedencentral'
}

# The worker often runs as SYSTEM. The Azure CLI, and kubelogin through it, use the worker's own profile. kubectl and
# Helm use the kubeconfig in the lab user's profile, which works for the attendee after their own Azure CLI sign-in.
$env:AZURE_CONFIG_DIR = $AzureConfigDir
$env:KUBECONFIG       = $Kubeconfig
$env:AZ_INSTALLER     = 'MSI'
$env:PYTHONIOENCODING = 'utf-8'
$env:HELM_CACHE_HOME  = Join-Path $LcaDir 'helm\cache'
$env:HELM_CONFIG_HOME = Join-Path $LcaDir 'helm\config'
$env:HELM_DATA_HOME   = Join-Path $LcaDir 'helm\data'
foreach ($dir in $K8sDir, 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin') {
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
}

function Write-Log([string]$Message) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    [IO.File]::AppendAllText($LogPath, $line + "`r`n", $Utf8)
    if ($SetupLogPath) { try { [IO.File]::AppendAllText($SetupLogPath, $line + "`r`n", $Utf8) } catch { } }
    if ($Manual) { Write-Host $line }
}

function Format-Elapsed([TimeSpan]$Span) {
    # For example "41 minutes 4 seconds", or "1 hour 0 minutes 12 seconds".
    if ($Span -lt [TimeSpan]::Zero) { $Span = [TimeSpan]::Zero }
    $hours = [int][Math]::Floor($Span.TotalHours)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($hours -gt 0) { $parts.Add($(if ($hours -eq 1) { '1 hour' } else { "$hours hours" })) }
    if ($hours -gt 0 -or $Span.Minutes -gt 0) { $parts.Add($(if ($Span.Minutes -eq 1) { '1 minute' } else { "$($Span.Minutes) minutes" })) }
    $parts.Add($(if ($Span.Seconds -eq 1) { '1 second' } else { "$($Span.Seconds) seconds" }))
    return ($parts -join ' ')
}

function Save-State([string]$Status, [string]$Message) {
    $state = [ordered]@{
        status    = $Status
        mode      = $Mode
        runId     = $RunId
        processId = $PID
        message   = $Message
        startedAt = $StartedAt
        updatedAt = (Get-Date).ToString('o')
        elapsed   = Format-Elapsed ([DateTimeOffset]::Now - $RunStart)
        log       = $LogPath
        setupLog  = $SetupLogPath
        signature = [string]$Cfg.Signature
        lab       = $Lab
        steps     = $Steps
        checks    = $Checks
    }
    $temp = "$StatePath.tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $state -Depth 6), $Utf8)
    Move-Item -LiteralPath $temp -Destination $StatePath -Force
}

function Write-RunSummary([string]$Status, [string]$Message) {
    # Ends both logs, but not the window, with the result, the total elapsed time, and the steps and readiness gate
    # checks that need attention. The window already showed them, and the launcher shows the result.
    $finished = [DateTimeOffset]::Now
    $title = if ($Mode -eq 'Verify') { 'LAB723 readiness gate' } else { 'LAB723 begin state' }
    $rule = '=' * 100
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($rule)
    $lines.Add("${title}: $($Status.ToUpperInvariant()). $Message")
    $lines.Add(('Started {0:yyyy-MM-dd HH:mm:ss}, finished {1:yyyy-MM-dd HH:mm:ss}. Total elapsed time: {2}.' -f
                $RunStart.LocalDateTime, $finished.LocalDateTime, (Format-Elapsed ($finished - $RunStart))))
    function Add-Results([string]$Title, $List, [string]$Name, [string]$Ok, [string]$None) {
        # Counts, and then each item that isn't $Ok, with its detail.
        $items = @(foreach ($item in $List) { $item })
        $lines.Add('')
        if ($items.Count -eq 0) { $lines.Add("${Title}: $None"); return }
        $counts = foreach ($result in $Ok, 'WARN', 'FAIL') { '{0} {1}' -f @($items | Where-Object { $_.result -eq $result }).Count, $result }
        $lines.Add("${Title}: $($counts -join ', ')")
        foreach ($item in @($items | Where-Object { $_.result -ne $Ok })) {
            $lines.Add(('  {0,-4}  {1}: {2}' -f $item.result, $item.$Name, $item.detail))
        }
    }
    Add-Results 'Steps' $Steps 'step' 'READY' 'none ran.'
    Add-Results 'Readiness gate' $Checks 'check' 'PASS' "didn't run."
    $lines.Add($rule)
    $text = ($lines -join "`r`n") + "`r`n"
    foreach ($path in @($LogPath, $SetupLogPath | Where-Object { $_ })) {
        try { [IO.File]::AppendAllText($path, $text, $Utf8) } catch { }
    }
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action, [switch]$Optional)
    Write-Log "==> $Name"
    Save-State 'Running' $Name
    try {
        $detail = [string](@(& $Action) | Select-Object -Last 1)
        $Steps.Add([pscustomobject]@{ step = $Name; result = 'READY'; detail = $detail })
        Write-Log "READY: $Name. $detail"
    } catch {
        $message = $_.Exception.Message
        $result = if ($Optional) { 'WARN' } else { 'FAIL' }
        $Steps.Add([pscustomobject]@{ step = $Name; result = $result; detail = $message })
        Write-Log "${result}: $Name. $message"
        if (-not $Optional) { throw "$Name failed. $message" }
    }
}

function Test-Resolved($Value) {
    # A token that Skillable didn't replace, including one with a space after the @.
    $text = [string]$Value
    return ($text.Length -gt 0 -and $text -notmatch '^@\s*lab\.')
}

function Limit-Text([string]$Text, [int]$Max = 600) {
    $flat = ($Text -replace '\s+', ' ').Trim()
    if ($flat.Length -gt $Max) { $flat = $flat.Substring(0, $Max) + '...' }
    return $flat
}

function Get-ErrorText([string]$Text) {
    # The lines that say what failed. Tools such as Helm print the cluster's warnings first, such as deployment safeguards'
    # notices, which would otherwise fill the message and hide the error.
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $noise = '(?i)warnings\.go:\d+\]|^warning\b'
    $picked = @($lines | Where-Object { $_ -match '(?i)^(error|fatal)\b|\berror\b' -and $_ -notmatch $noise })
    if ($picked.Count -eq 0) { $picked = @($lines | Where-Object { $_ -notmatch $noise }) }
    if ($picked.Count -eq 0) { $picked = $lines }
    return ($picked -join ' ')
}

function Get-LastErrorLine([string]$Text) {
    # A tool's own error: the last line of its error output that isn't a log line or a warning, such as the Kubernetes
    # client's notes about requests that it retried, which a command that fails for another reason can print too.
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } |
               Where-Object { $_ -and $_ -notmatch '^[IWEF]\d{4} \d{2}:\d{2}:\d{2}\.\d+\s' -and $_ -notmatch '(?i)^warning\b' })
    if ($lines.Count -eq 0) { return '' }
    return $lines[$lines.Count - 1]
}

function Invoke-Tool {
    param([string]$FilePath, [string[]]$Arguments, [string]$Display, [switch]$AllowFailure, [string]$RetryOn)
    # Native tools write warnings to stderr. Capture both streams, and judge success by the exit code. A failure whose own
    # error matches RetryOn, such as $KubeTransient, gets more tries, as $TransientRetry sets.
    for ($attempt = 1; $true; $attempt++) {
        $global:LASTEXITCODE = 0
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = @(& $FilePath @Arguments 2>&1)
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
        $stdout = @($raw | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        $stderr = @($raw | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.Exception.Message })
        $result = [pscustomobject]@{ ExitCode = $code; Out = ($stdout -join "`n"); Err = ($stderr -join "`n") }
        if (-not $RetryOn) { break }
        if ($code -eq 0) {
            if ($attempt -gt 1) { Write-Log "  $Display worked on try $attempt." }
            break
        }
        $line = Get-LastErrorLine $result.Err
        if ($line -notmatch $RetryOn -or $attempt -ge $TransientRetry.Attempts) { break }
        $wait = $attempt * $TransientRetry.DelaySeconds
        if ($TransientRetry.Exhausted -or $TransientRetry.Spent + $wait -gt $TransientRetry.BudgetSeconds) {
            if (-not $TransientRetry.Exhausted) {
                $TransientRetry.Exhausted = $true
                Write-Log ("  $Display failed with an error that usually passes, but this run has already waited " +
                           "$($TransientRetry.Spent) seconds for retries, its limit, so no command is tried again.")
            }
            break
        }
        Write-Log ("  $Display failed on try $attempt of $($TransientRetry.Attempts) with an error that usually passes. " +
                   "Trying again in $wait seconds. $(Limit-Text $line)")
        $TransientRetry.Spent += $wait
        Start-Sleep -Seconds $wait
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        # The logs get the tool's whole output. The message, which the step's result shows, gets the lines that say what failed.
        $lines = @(($result.Err, $result.Out) -join "`n" -split "`r?`n" | Where-Object { $_.Trim() })
        Write-Log ("  $Display failed (exit code $code). Its output" + $(if ($lines.Count -gt 200) { ', first 200 lines' } else { '' }) + ':')
        foreach ($line in @($lines | Select-Object -First 200)) { Write-Log "    $($line.TrimEnd())" }
        throw "$Display failed (exit code $code). $(Limit-Text (Get-ErrorText $result.Err))"
    }
    return $result
}

function Invoke-Az {
    param([string[]]$Arguments, [string]$Display, [switch]$AllowFailure)
    # Runs the Azure CLI's Python directly, as az.cmd does, so that cmd.exe can't reinterpret arguments.
    if (-not $Display) { $Display = 'az ' + (($Arguments | Select-Object -First 3) -join ' ') }
    return Invoke-Tool -FilePath $AzPython -Arguments (@('-IBm', 'azure.cli') + $Arguments + @('--only-show-errors')) `
                       -Display $Display -AllowFailure:$AllowFailure
}

function Get-AzJson([string[]]$Arguments, [switch]$AllowFailure) {
    # On failure this returns nothing rather than $null, because @($null) counts as one item.
    $result = Invoke-Az -Arguments ($Arguments + @('--output', 'json')) -AllowFailure:$AllowFailure
    if ($result.ExitCode -ne 0 -or -not $result.Out.Trim()) { return }
    $parsed = $result.Out | ConvertFrom-Json
    return $parsed
}

function Get-AzText([string[]]$Arguments, [switch]$AllowFailure) {
    $result = Invoke-Az -Arguments ($Arguments + @('--output', 'tsv')) -AllowFailure:$AllowFailure
    if ($result.ExitCode -ne 0) { return '' }
    return $result.Out.Trim()
}

function Invoke-Kubectl([string[]]$Arguments, [switch]$AllowFailure) {
    # Every kubectl command that the LCA runs can run again: apply and patch set a state, and delete ignores what's gone.
    return Invoke-Tool -FilePath $KubectlExe -Arguments (@('--kubeconfig', $Kubeconfig) + $Arguments) `
                       -Display ('kubectl ' + ($Arguments -join ' ')) -AllowFailure:$AllowFailure -RetryOn $KubeTransient
}

function Get-KubeJson([string[]]$Arguments) {
    $result = Invoke-Kubectl -Arguments ($Arguments + @('--output', 'json')) -AllowFailure
    if ($result.ExitCode -ne 0 -or -not $result.Out.Trim()) { return }
    return ($result.Out | ConvertFrom-Json)
}

function Get-KubeItems([string[]]$Arguments, [switch]$MissingTypeIsEmpty) {
    # Returns the items of a list. Throws when kubectl fails, so that a check can't pass on an error.
    $result = Invoke-Kubectl -Arguments ($Arguments + @('--output', 'json')) -AllowFailure
    if ($result.ExitCode -ne 0) {
        if ($MissingTypeIsEmpty -and $result.Err -match "doesn't have a resource type") { return }
        throw "kubectl $($Arguments -join ' ') failed. $(Limit-Text $result.Err 200)"
    }
    $parsed = $result.Out | ConvertFrom-Json
    foreach ($item in @($parsed.items)) { if ($null -ne $item) { $item } }
}

function ConvertTo-Cores([string]$Quantity) {
    if (-not $Quantity) { return 0.0 }
    if ($Quantity.EndsWith('m')) { return ([double]$Quantity.TrimEnd('m')) / 1000 }
    return [double]$Quantity
}

function ConvertTo-GiB([string]$Quantity) {
    # A Kubernetes memory quantity, such as 512Mi, 2Gi, 16323892Ki, 2G, or a number of bytes, in GiB.
    if ($Quantity -notmatch '^([0-9.]+(?:[eE][-+]?[0-9]+)?)([a-zA-Z]*)$') { return 0.0 }
    $bytes = [double]$Matches[1]
    switch -CaseSensitive ($Matches[2]) {
        ''      { }
        'Ki'    { $bytes *= 1KB }
        'Mi'    { $bytes *= 1MB }
        'Gi'    { $bytes *= 1GB }
        'Ti'    { $bytes *= 1TB }
        'k'     { $bytes *= 1e3 }
        'M'     { $bytes *= 1e6 }
        'G'     { $bytes *= 1e9 }
        'T'     { $bytes *= 1e12 }
        'm'     { $bytes /= 1000 }
        default { return 0.0 }
    }
    return $bytes / 1GB
}

function Test-NodeReady($Node) {
    return (@($Node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0)
}

function Test-GpuNode($Node) {
    return ($Node.metadata.labels.'karpenter.sh/nodepool' -eq 'gpu' -or [bool]$Node.status.allocatable.'nvidia.com/gpu')
}

function Get-PodRequest($Pod) {
    # The CPUs and GiB that the scheduler sets aside for a pod: its containers and sidecars, or its largest init container
    # if that's more.
    $cpu = 0.0; $memory = 0.0; $initCpu = 0.0; $initMemory = 0.0
    foreach ($container in @($Pod.spec.containers | Where-Object { $_ })) {
        $cpu += ConvertTo-Cores ([string]$container.resources.requests.cpu)
        $memory += ConvertTo-GiB ([string]$container.resources.requests.memory)
    }
    foreach ($container in @($Pod.spec.initContainers | Where-Object { $_ })) {
        $containerCpu = ConvertTo-Cores ([string]$container.resources.requests.cpu)
        $containerMemory = ConvertTo-GiB ([string]$container.resources.requests.memory)
        if ($container.restartPolicy -eq 'Always') { $cpu += $containerCpu; $memory += $containerMemory }
        else { $initCpu = [Math]::Max($initCpu, $containerCpu); $initMemory = [Math]::Max($initMemory, $containerMemory) }
    }
    return [pscustomobject]@{ Cpu = [Math]::Max($cpu, $initCpu); Memory = [Math]::Max($memory, $initMemory) }
}

function Get-LabCapacity([switch]$InUse) {
    # The lab nodes: CPU nodes where the lab's pods can run, which are ready and schedulable and have no NoSchedule taint.
    # For each one: its VM size, the CPUs and GiB that no pod has requested, and the capacity reserve's share. Held means
    # that a pod other than a DaemonSet's or the capacity reserve's runs there, so NAP never removes the node as empty.
    # InUse leaves out nodes with only DaemonSet pods, which NAP removes within a minute.
    $nodes = @(Get-KubeItems @('get', 'nodes') | Where-Object {
        -not (Test-GpuNode $_) -and (Test-NodeReady $_) -and -not $_.spec.unschedulable -and
        @($_.spec.taints | Where-Object { $_.effect -eq 'NoSchedule' }).Count -eq 0 })
    $pods = @(Get-KubeItems @('get', 'pods', '--all-namespaces', '--field-selector', 'status.phase!=Succeeded,status.phase!=Failed'))
    foreach ($node in $nodes) {
        $name = [string]$node.metadata.name
        $cpu = 0.0; $memory = 0.0; $capacityCpu = 0.0; $capacityMemory = 0.0; $held = $false
        foreach ($pod in @($pods | Where-Object { $_.spec.nodeName -eq $name })) {
            $request = Get-PodRequest $pod
            $cpu += $request.Cpu
            $memory += $request.Memory
            if ($pod.metadata.namespace -eq $CapacityNs) {
                $capacityCpu += $request.Cpu
                $capacityMemory += $request.Memory
            } elseif (@($pod.metadata.ownerReferences | Where-Object { $_.kind -eq 'DaemonSet' }).Count -eq 0) {
                $held = $true
            }
        }
        if ($InUse -and -not $held -and $capacityCpu -le 0) { continue }
        [pscustomobject]@{
            Name           = $name
            Size           = [string]$node.metadata.labels.'node.kubernetes.io/instance-type'
            Cpu            = (ConvertTo-Cores ([string]$node.status.allocatable.cpu)) - $cpu
            Memory         = (ConvertTo-GiB ([string]$node.status.allocatable.memory)) - $memory
            CapacityCpu    = $capacityCpu
            CapacityMemory = $capacityMemory
            Held           = $held
        }
    }
}

function Test-WarmCapacity($Nodes) {
    # Whether the lab nodes' spare capacity is what Exercises 2 to 4 need ($Warm). Enough: Exercises 2 and 3 don't wait
    # for a node. Passed: that, and Exercise 4's scale-out needs a new node.
    $list = @($Nodes | Where-Object { $_ })
    $total = 0.0
    $reserved = 0.0
    foreach ($node in $list) { $total += $node.Cpu; $reserved += $node.CapacityCpu }
    $best = @($list | Where-Object { $_.Memory -ge $Warm.LargeGiB } | Sort-Object -Property Cpu -Descending | Select-Object -First 1)
    $enough = $total -ge $Warm.MinCpu -and $best.Count -gt 0 -and $best[0].Cpu -ge $Warm.LargeCpu
    $sizes = @($list | ForEach-Object { if ($_.Size) { $_.Size } else { $_.Name } })
    $sizeText = if ($sizes.Count) { " ($($sizes -join ', '))" } else { '' }
    $bestText = if ($best.Count) { 'up to {0:N1} CPUs and {1:N1} GiB on one node' -f $best[0].Cpu, $best[0].Memory }
                else { "no node with $($Warm.LargeGiB) GiB free" }
    $text = ('Spare on {0} lab {1}{2}: {3:N1} CPUs in total, and {4}. Target: {5} to {6} CPUs in total, and {7} CPUs and {8} GiB on one node.' -f
             $list.Count, $(if ($list.Count -eq 1) { 'node' } else { 'nodes' }), $sizeText, $total, $bestText, $Warm.MinCpu, $Warm.MaxCpu,
             $Warm.LargeCpu, $Warm.LargeGiB)
    if ($reserved -gt 0) { $text += (' The capacity reserve in {0} holds {1:N2} more CPUs.' -f $CapacityNs, $reserved) }
    return [pscustomobject]@{ Passed = ($enough -and $total -lt $Warm.MaxCpu); Enough = $enough; Total = $total; Text = $text }
}

function Invoke-Apply([string]$Name, [string]$Yaml) {
    New-Item -ItemType Directory -Path $Manifests -Force | Out-Null
    $file = Join-Path $Manifests "$Name.yaml"
    [IO.File]::WriteAllText($file, $Yaml, $Utf8)
    Invoke-Kubectl @('apply', '-f', $file) | Out-Null
}

function Format-Template([string]$Template, [hashtable]$Values) {
    $text = $Template
    foreach ($key in $Values.Keys) { $text = $text.Replace("__$($key)__", [string]$Values[$key]) }
    if ($text -match '__[A-Z0-9_]+__') { throw "The manifest template has no value for $($Matches[0])." }
    return $text
}

function Wait-Until([string]$What, [int]$Minutes, [scriptblock]$Condition, [int]$IntervalSeconds = 20) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ($true) {
        $value = & $Condition
        if ($value) { return $value }
        if ((Get-Date) -gt $deadline) { throw "Timed out after $Minutes minutes waiting for $What." }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Test-RoleAssignment([string]$PrincipalId, [string]$Role, [string]$Scope) {
    $ids = @(Get-AzJson @('role', 'assignment', 'list', '--scope', $Scope, '--role', $Role, '--fill-principal-name', 'false',
                          '--query', "[?principalId=='$PrincipalId'].id") -AllowFailure)
    return ($ids.Count -gt 0)
}

function Get-ServedVersion([string]$Crd) {
    $definition = Get-KubeJson @('get', 'crd', $Crd)
    if (-not $definition) { return '' }
    $served = @($definition.spec.versions | Where-Object { $_.served } | ForEach-Object { $_.name })
    $pick = if ($served -contains 'v1') { 'v1' } elseif ($served -contains 'v1beta1') { 'v1beta1' } else { $served[0] }
    return "$($definition.spec.group)/$pick"
}

function Get-BlobCount {
    $result = Invoke-Az @('storage', 'blob', 'list', '--account-name', $Lab.storageName, '--container-name', $Cfg.ModelContainer,
                          '--auth-mode', 'login', '--num-results', '100', '--query', 'length(@)', '--output', 'tsv') -AllowFailure
    if ($result.ExitCode -ne 0) { return -1 }
    return [int]$result.Out.Trim()
}

function Get-GpuFeatureState {
    # Registered, Registering, Pending, NotRegistered, or Unregistered. NotFound: the subscription doesn't offer
    # the feature. Unknown: the state couldn't be read.
    $result = Invoke-Az @('feature', 'show', '--namespace', 'Microsoft.ContainerService', '--name', 'ManagedGPUExperiencePreview',
                          '--query', 'properties.state', '--output', 'tsv') -AllowFailure
    if ($result.ExitCode -eq 0 -and $result.Out.Trim()) { return $result.Out.Trim() }
    if ($result.Err -match 'FeatureNotFound|could not be found|was not found') { return 'NotFound' }
    return 'Unknown'
}

function Get-NotReady([string]$Name, $Object) {
    # Why a Karpenter object, such as a NodePool or an AKSNodeClass, reports that it isn't ready, or nothing if it's ready.
    $ready = @($Object.status.conditions | Where-Object { $_ -and $_.type -eq 'Ready' }) | Select-Object -First 1
    if (-not $ready -or [string]$ready.status -eq 'True') { return '' }
    $why = @([string]$ready.reason, [string]$ready.message | Where-Object { $_ }) -join ': '
    if (-not $why) { $why = "Ready is $($ready.status)" }
    return "$Name isn't ready ($why)"
}

function Test-GpuAccess {
    # NAP skips the gpu NodePool when this subscription can't use its VM size in the lab's region, and the GPU pod in
    # Exercise 3 then stays Pending, with a karpenter event that names only the other NodePools. So check that the size
    # isn't restricted for the subscription, in the region and in at least one of its zones, and that the size's family
    # quota and the regional vCPU quota have room for one GPU node. Returns @(passed, detail), or adds WARN when it can't tell.
    $size = [string]$Cfg.GpuVmSize
    $region = [string]$Lab.location
    if (-not $region) { return @($false, "The lab's region isn't known, so $size wasn't checked.", 'WARN') }
    # The Resource SKUs API, filtered to the region, lists restricted sizes too. It takes seconds, and az vm list-skus about a minute.
    $url = '/subscriptions/{subscriptionId}/providers/Microsoft.Compute/skus?api-version=2021-07-01&$filter=location eq ''' + $region + ''''
    $list = Invoke-Az @('rest', '--method', 'get', '--url', $url, '--query', "value[?name=='$size' && resourceType=='virtualMachines']",
                        '--output', 'json') -Display 'az rest Microsoft.Compute/skus' -AllowFailure
    if ($list.ExitCode -ne 0) { return @($false, "Couldn't read the VM sizes in $region. $(Limit-Text (Get-ErrorText $list.Err) 300)", 'WARN') }
    # ForEach-Object unrolls the array, which ConvertFrom-Json in Windows PowerShell returns as one object.
    $sku = @($list.Out | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.name -eq $size }) | Select-Object -First 1
    if (-not $sku) { return @($false, "$size isn't offered in $region. Use a region that has it, or set GpuVmSize to an NVIDIA size that $region has.") }
    $fix = "Ask the subscription's owner, Skillable for a lab, to enable it, or use another region or GPU size."
    $restrictions = @($sku.restrictions | Where-Object { $_ })
    $regionWide = @($restrictions | Where-Object { $_.type -eq 'Location' }) | Select-Object -First 1
    if ($regionWide) { return @($false, "$size is restricted for this subscription in $region ($($regionWide.reasonCode)). $fix") }
    $zones = @($sku.locationInfo | Where-Object { $_.location -eq $region } | ForEach-Object { $_.zones } | Where-Object { $_ } | Sort-Object -Unique)
    $closed = @($restrictions | Where-Object { $_.type -eq 'Zone' } | ForEach-Object { $_.restrictionInfo.zones } | Where-Object { $_ })
    $open = @($zones | Where-Object { $closed -notcontains $_ })
    if ($zones.Count -gt 0 -and $open.Count -eq 0) {
        $reason = @($restrictions | ForEach-Object { $_.reasonCode } | Where-Object { $_ } | Select-Object -Unique) -join ', '
        return @($false, "$size is restricted for this subscription in every zone of $region ($reason). $fix")
    }
    $where = if ($open.Count) { "$region, zones $($open -join ', ')" } else { $region }
    $cpus = [int](@($sku.capabilities | Where-Object { $_.name -eq 'vCPUs' }) | Select-Object -First 1).value
    $usage = Invoke-Az @('vm', 'list-usage', '--location', $region, '--output', 'json') -Display 'az vm list-usage' -AllowFailure
    if ($usage.ExitCode -ne 0) {
        return @($false, "$size is available in $where, but its quota couldn't be read. $(Limit-Text (Get-ErrorText $usage.Err) 300)", 'WARN')
    }
    $usages = @($usage.Out | ConvertFrom-Json | ForEach-Object { $_ })
    $short = New-Object System.Collections.Generic.List[string]
    $counts = New-Object System.Collections.Generic.List[string]
    # The Azure CLI shows the family as "Standard NCASv3_T4 Family", in both lists, and the API as standardNCASv3_T4Family.
    foreach ($key in @([string]$sku.family, 'cores')) {
        $wanted = ($key -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        $entry = @($usages | Where-Object { (([string]$_.name.value) -replace '[^A-Za-z0-9]', '').ToLowerInvariant() -eq $wanted }) |
                 Select-Object -First 1
        if (-not $entry) { return @($false, "$size is available in $where, but there's no quota entry for $key.", 'WARN') }
        $label = if ($entry.localName) { [string]$entry.localName } else { [string]$entry.name.localizedValue }
        $used = [int]$entry.currentValue
        $limit = [int]$entry.limit
        $counts.Add("$label $used of $limit used")
        if ($limit - $used -lt $cpus) { $short.Add("$label is $limit, with $used in use, and one $size needs $cpus") }
    }
    if ($short.Count -gt 0) { return @($false, "$size is available in $where, but its quota is too small: $($short -join '; '). Ask for more quota.") }
    return @($true, "$size is available to this subscription in $where. Quota: $($counts -join ', ').")
}

function Get-RunStatus([int]$Failures, [int]$StepWarnings) {
    # Incomplete runs are repeated in full by the next run of the LCA. Only Failed fails the action.
    if ($Failures -gt 0 -and ($Mode -eq 'Verify' -or $Cfg.GateFailsPrepare)) { return 'Failed' }
    if ($Failures -gt 0 -or $StepWarnings -gt 0) { return 'Incomplete' }
    return 'Succeeded'
}

function Protect-Folder([string]$Path) {
    # Only SYSTEM, administrators, and the identity that runs the worker can open the folder.
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Invoke-Tool -FilePath (Join-Path $env:SystemRoot 'System32\icacls.exe') -Display "icacls $Path" -Arguments @(
        $Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "*${me}:(OI)(CI)F") | Out-Null
}

function Test-CredentialRemoval([int]$Failures, [int]$StepWarnings) {
    # The readiness gate LCA is the last one before the attendee gets the VM, so it removes the credentials. AfterPrepare
    # removes them after a clean prepare run instead, for a profile without that LCA. A run that isn't clean keeps
    # them, because the next run needs them. A manual run has none: it uses your own sign-in.
    if ($Manual) { return $false }
    switch ([string]$Cfg.RemoveCredentials) {
        'AfterGate'    { return ($Mode -eq 'Verify') }
        'AfterPrepare' { return ($Mode -eq 'Verify' -or ($Failures -eq 0 -and $StepWarnings -eq 0)) }
    }
    return $false
}

function Clear-EventLogChannel([string]$Name) {
    [Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($Name)
}

function Clear-ScriptLog {
    # Windows PowerShell writes the text of a script that it considers suspicious, such as this LCA, to its event log
    # (event 4104), even when script block logging is off, and any user who signs in to the VM can read that log.
    # Skillable puts the token values in the LCA's text before it runs, so the log has the service principal's secret.
    # Clears the PowerShell logs that can hold a script's text, looks for the service principal's application ID in
    # them, and returns what's left.
    $logs = 'Microsoft-Windows-PowerShell/Operational', 'PowerShellCore/Operational', 'Windows PowerShell'
    $left = New-Object System.Collections.Generic.List[string]
    foreach ($log in $logs) {
        if (-not (Get-WinEvent -ListLog $log -ErrorAction SilentlyContinue)) { continue }
        try { Clear-EventLogChannel $log } catch {
            $left.Add("the $log event log, which couldn't be cleared: $(([string]$_.Exception.Message).TrimEnd('.'))")
        }
    }
    $id = [string]$Cfg.ClientId
    if (Test-Resolved $id) {
        foreach ($log in $logs) {
            $events = @(try { Get-WinEvent -LogName $log -ErrorAction Stop } catch { })
            $found = @($events | Where-Object { $_.ToXml() -match [regex]::Escape($id) }).Count
            $count = if ($found -eq 1) { '1 event' } else { "$found events" }
            if ($found) { $left.Add("$count in the $log event log with the service principal's application ID") }
        }
    }
    return $left
}

function Remove-CloudCredential {
    # Deletes the worker's Azure CLI profile, which is signed in as the service principal, and clears the PowerShell event
    # logs, which have this LCA's text with the service principal's secret, so that the attendee can't get the service
    # principal. Adds a readiness gate row, and returns 1 if something is left.
    $script:CredentialsRemoved = $true
    $left = New-Object System.Collections.Generic.List[string]
    # Never the Azure CLI profile of a manual run, which is your own.
    if (-not $Manual) {
        for ($attempt = 1; $attempt -le 3 -and (Test-Path -LiteralPath $AzureConfigDir); $attempt++) {
            Remove-Item -LiteralPath $AzureConfigDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $AzureConfigDir) { Start-Sleep -Seconds 2 }
        }
        if (Test-Path -LiteralPath $AzureConfigDir) { $left.Add($AzureConfigDir) }
    }
    foreach ($item in @(Clear-ScriptLog)) { $left.Add($item) }
    $detail = if ($left.Count -eq 0) { "Deleted $AzureConfigDir, and cleared the PowerShell event logs, which had the LCA's text" }
              else { "Still in the VM: $($left -join '; '). Remove them before an attendee uses this VM." }
    $Checks.Add([pscustomobject]@{ check = 'Cloud credentials removed'; result = $(if ($left.Count -eq 0) { 'PASS' } else { 'FAIL' })
                                   detail = $detail })
    Write-Log "Cloud credentials removed: $detail"
    return [int]($left.Count -gt 0)
}

function New-LabMutex {
    # Any signed-in identity can open the lock, so a SYSTEM worker and an administrator's readiness gate share it.
    $name = 'Global\LAB723-lca'
    $created = $false
    try {
        $security = New-Object Security.AccessControl.MutexSecurity
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-11') {
            $security.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule(
                (New-Object Security.Principal.SecurityIdentifier($sid)), [Security.AccessControl.MutexRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow)))
        }
        return [Threading.Mutex]::new($false, $name, [ref]$created, $security)
    } catch {
        # PowerShell 7 has no constructor that takes an ACL. If access is denied, this throws too.
        return [Threading.Mutex]::new($false, $name)
    }
}

# ---------------------------------------------------------------------------------------------
# Manifest templates. __NAME__ placeholders are filled in by Format-Template. Every pod has a
# pinned image tag, probes, and requests equal to limits, so deployment safeguards accept it.
# ---------------------------------------------------------------------------------------------
$NamespacesYaml = @'
apiVersion: v1
kind: Namespace
metadata:
  name: ai-lab
---
apiVersion: v1
kind: Namespace
metadata:
  name: ray
'@

$LabSettingsYaml = @'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: inference
  namespace: ai-lab
  annotations:
    azure.workload.identity/client-id: "__CLIENT_ID__"
    azure.workload.identity/tenant-id: "__TENANT_ID__"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-environment
  namespace: ai-lab
data:
  REGISTRY: "__REGISTRY__"
  MODEL_STORAGE_ACCOUNT: "__STORAGE_ACCOUNT__"
  MODEL_ACCOUNT_URL: "https://__STORAGE_ACCOUNT__.blob.core.windows.net"
  MODEL_CONTAINER: "__MODEL_CONTAINER__"
'@

$AppInsightsSecretYaml = @'
apiVersion: v1
kind: Secret
metadata:
  name: appinsights
  namespace: ai-lab
type: Opaque
data:
  APPLICATIONINSIGHTS_CONNECTION_STRING: __CONNECTION_STRING__
'@

$GpuPoolYaml = @'
apiVersion: __NODECLASS_API__
kind: AKSNodeClass
metadata:
  name: gpu
spec:
  tags:
    EnableManagedGPUExperience: "true"
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: gpu
      taints:
        - key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule
      expireAfter: Never
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.azure.com/sku-name
          operator: In
          values: ["__GPU_VM_SIZE__"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
  limits:
    cpu: "__GPU_CPU_LIMIT__"
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
'@

$ServiceMonitorYaml = @'
apiVersion: azmonitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: lab723-inference
  namespace: ai-lab
spec:
  labelLimit: 63
  labelNameLengthLimit: 511
  labelValueLengthLimit: 1023
  selector:
    matchExpressions:
      - key: app
        operator: In
        values: ["inference", "inference-gpu"]
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
      scheme: http
'@

$RayClusterYaml = @'
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: ray-lab
  namespace: ray
spec:
  rayVersion: "__RAY_VERSION__"
  enableInTreeAutoscaling: false
  headGroupSpec:
    serviceType: ClusterIP
    rayStartParams:
      dashboard-host: "0.0.0.0"
      num-cpus: "0"
    template:
      metadata:
        labels:
          app: ray-lab
        annotations:
          karpenter.sh/do-not-disrupt: "true"
      spec:
        containers:
          - name: ray-head
            image: __RAY_IMAGE__
            ports:
              - containerPort: 6379
                name: gcs-server
              - containerPort: 8265
                name: dashboard
              - containerPort: 10001
                name: client
            resources:
              requests:
                cpu: "1"
                memory: 4Gi
              limits:
                cpu: "1"
                memory: 4Gi
            volumeMounts:
              - name: dshm
                mountPath: /dev/shm
        volumes:
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: 1Gi
  workerGroupSpecs:
    - groupName: cpu
      replicas: __RAY_WORKERS__
      minReplicas: __RAY_WORKERS__
      maxReplicas: __RAY_WORKERS__
      rayStartParams: {}
      template:
        metadata:
          labels:
            app: ray-lab
          annotations:
            karpenter.sh/do-not-disrupt: "true"
        spec:
          containers:
            - name: ray-worker
              image: __RAY_IMAGE__
              resources:
                requests:
                  cpu: "1"
                  memory: 3Gi
                limits:
                  cpu: "1"
                  memory: 3Gi
              volumeMounts:
                - name: dshm
                  mountPath: /dev/shm
          volumes:
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 1Gi
'@

$NotebookYaml = @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lab-notebook
  namespace: ray
  labels:
    app: lab-notebook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lab-notebook
  template:
    metadata:
      labels:
        app: lab-notebook
      annotations:
        karpenter.sh/do-not-disrupt: "true"
    spec:
      containers:
        - name: notebook
          image: __NOTEBOOK_IMAGE__
          ports:
            - name: http
              containerPort: 8888
          env:
            - name: RAY_ADDRESS
              value: ray://ray-lab-head-svc.ray.svc.cluster.local:10001
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              cpu: "1"
              memory: 2Gi
          readinessProbe:
            httpGet:
              path: /api
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api
              port: http
            initialDelaySeconds: 30
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: lab-notebook
  namespace: ray
  labels:
    app: lab-notebook
spec:
  type: ClusterIP
  selector:
    app: lab-notebook
  ports:
    - name: http
      port: 8888
      targetPort: http
'@

$LabClientYaml = @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lab-client
  namespace: ai-lab
  labels:
    app: lab-client
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lab-client
  template:
    metadata:
      labels:
        app: lab-client
      annotations:
        karpenter.sh/do-not-disrupt: "true"
    spec:
      containers:
        - name: lab-client
          image: __LAB_CLIENT_IMAGE__
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            exec:
              command: ["sh", "-c", "command -v predict && command -v bench"]
            periodSeconds: 30
          livenessProbe:
            exec:
              command: ["sh", "-c", "command -v bench"]
            periodSeconds: 60
'@

$LoadgenYaml = @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loadgen
  namespace: ai-lab
  labels:
    app: loadgen
spec:
  replicas: 0
  selector:
    matchLabels:
      app: loadgen
  template:
    metadata:
      labels:
        app: loadgen
    spec:
      containers:
        - name: loadgen
          image: __LOADGEN_IMAGE__
          env:
            - name: TARGET_URL
              value: http://inference.ai-lab.svc.cluster.local
          resources:
            requests:
              cpu: 500m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 256Mi
          readinessProbe:
            exec:
              command: ["sh", "-c", "kill -0 1"]
            periodSeconds: 30
          livenessProbe:
            exec:
              command: ["sh", "-c", "kill -0 1"]
            periodSeconds: 60
'@

$IdentityCheckYaml = @'
apiVersion: batch/v1
kind: Job
metadata:
  name: lab723-wi-check
  namespace: ai-lab
spec:
  backoffLimit: 6
  activeDeadlineSeconds: 900
  template:
    metadata:
      labels:
        app: lab723-wi-check
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: inference
      restartPolicy: Never
      containers:
        - name: check
          image: __SMOKE_TEST_IMAGE__
          command: ["/bin/sh", "-c"]
          args:
            - >-
              az login --service-principal --username "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID"
              --federated-token "$(cat "$AZURE_FEDERATED_TOKEN_FILE")" --allow-no-subscriptions --output none &&
              az storage blob list --account-name __STORAGE_ACCOUNT__ --container-name __MODEL_CONTAINER__
              --auth-mode login --num-results 5 --query "[].name" --output tsv &&
              echo WORKLOAD_IDENTITY_OK
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 250m
              memory: 512Mi
          readinessProbe:
            exec:
              command: ["/bin/sh", "-c", "exit 0"]
          livenessProbe:
            exec:
              command: ["/bin/sh", "-c", "exit 0"]
'@

$CapacityNamespaceYaml = @'
apiVersion: v1
kind: Namespace
metadata:
  name: lab723-capacity
'@

# A pod that only requests CPU. With a node, it's part of the capacity reserve, which holds spare CPU on that node. Without
# one, it's the placeholder that has NAP add a node. Deployment safeguards need its probes and its versioned image.
$CapacityYaml = @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: __NAME__
  namespace: lab723-capacity
  labels:
    app: lab723-capacity
    lab723-capacity/role: __ROLE__
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: lab723-capacity
      lab723-capacity/name: __NAME__
  template:
    metadata:
      labels:
        app: lab723-capacity
        lab723-capacity/name: __NAME__
        lab723-capacity/role: __ROLE__
      annotations:
        karpenter.sh/do-not-disrupt: "true"
    spec:
      terminationGracePeriodSeconds: 1
      automountServiceAccountToken: false
__AFFINITY__      containers:
        - name: hold
          image: __IMAGE__
          command: ["sleep", "infinity"]
          resources:
            requests: { cpu: __CPU__, memory: __MEMORY__ }
            limits: { cpu: __CPU__, memory: __MEMORY__ }
          readinessProbe:
            exec:
              command: ["sh", "-c", "true"]
            periodSeconds: 60
          livenessProbe:
            exec:
              command: ["sh", "-c", "true"]
            periodSeconds: 60
'@

# ---------------------------------------------------------------------------------------------
# The LAB723 resource template, "LAB723 resource template.json" in this folder, compressed. Only a
# manual run uses it, when the resource group has no deployment of the template.
# "LAB723 resource template - build.ps1" writes this block. Edit the .bicep file, and then run it.
# ---------------------------------------------------------------------------------------------
# >>> Resource template bundle
$TemplateBundleHash = '5CCCBBFE4349CE0A248ADAD97E52BB847B0FF1B288937D138B8ECF5FFD996895'
$TemplateBundle = @'
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
AA==
'@
# <<< Resource template bundle

# ---------------------------------------------------------------------------------------------
# Azure steps
# ---------------------------------------------------------------------------------------------
function Initialize-Context {
    if (-not (Test-Resolved $Cfg.ResourceGroup)) {
        throw ('ResourceGroup has no value. Check its token in the settings at the top of the LCA script, and check that the ' +
               'lab profile has a cloud subscription pool and the resource group that the token names.')
    }
    foreach ($name in 'TenantId', 'SubscriptionId', 'ClientId') {
        if ($Manual -and $name -eq 'ClientId') { continue }
        if (-not (Test-Resolved $Cfg.$name)) {
            throw "$name has no value. It comes from the CLOUD CREDENTIALS section at the top of the LCA script, which a pool admin turns on."
        }
    }
    if ($Mode -eq 'Prepare' -and -not $Manual -and -not (Test-Resolved $Cfg.ClientSecret)) {
        throw 'ClientSecret has no value. It comes from the CLOUD CREDENTIALS section at the top of the LCA script, which a pool admin turns on.'
    }
    if ([string]$Cfg.RemoveCredentials -notin 'AfterGate', 'AfterPrepare', 'Never') {
        throw "RemoveCredentials is '$($Cfg.RemoveCredentials)'. Use AfterGate, AfterPrepare, or Never."
    }
    foreach ($tool in $AzPython, $KubectlExe, $KubeloginExe, $HelmExe) {
        if (-not (Test-Path -LiteralPath $tool)) { throw "$tool is missing. Build the image with LAB723 VM image setup.ps1." }
    }
    if (-not (Test-Path -LiteralPath $Cfg.LabProfile)) { throw "The lab user's profile folder $($Cfg.LabProfile) doesn't exist." }
    New-Item -ItemType Directory -Path $LabAzureDir, (Split-Path -Parent $Kubeconfig), $Manifests -Force | Out-Null
    if ($Mode -eq 'Prepare' -and -not $Manual) { Protect-Folder $AzureConfigDir }
    $how = if ($Manual) { 'Manual run, as your own Azure CLI sign-in' } else { 'Life cycle action' }
    return ("$how. Lab user $($Cfg.LabUser) ($($Cfg.LabProfile)). Worker identity: " +
            [Security.Principal.WindowsIdentity]::GetCurrent().Name)
}

function Get-TokenObjectId {
    # The signed-in identity's object ID comes from its own token, so no Microsoft Graph permission is needed.
    $token = Get-AzText @('account', 'get-access-token', '--query', 'accessToken')
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    return [string]$claims.oid
}

function Connect-Azure {
    if ($Manual) {
        # A manual run uses the Azure CLI sign-in that the script checked when it started: you, as the portal user.
        $account = Get-AzJson @('account', 'show') -AllowFailure
        if (-not $account -or $account.user.type -ne 'user') {
            throw 'The Azure CLI must be signed in with your lab account. Run az login, and then run this script again.'
        }
        Invoke-Az @('account', 'set', '--subscription', $Cfg.SubscriptionId) | Out-Null
        $script:SpObjectId = Get-TokenObjectId
        $Lab.deployerObjectId = $SpObjectId
        return "Signed in as $($account.user.name) (object ID $SpObjectId), your own Azure CLI sign-in, to subscription $($Cfg.SubscriptionId)"
    }
    # The worker's own Azure CLI profile, which the lab user can't open. Its token cache is plain text, so that a
    # readiness gate that runs as another administrator can read it, and the readiness gate LCA deletes the profile
    # before the attendee gets the VM.
    Invoke-Az @('config', 'set', 'core.encrypt_token_cache=false', 'core.login_experience_v2=off',
                'core.collect_telemetry=false', 'core.survey_message=false', 'auto-upgrade.enable=no') | Out-Null
    # Retry briefly, in case the network or Microsoft Entra ID isn't ready right after the VM starts.
    $script:LoginError = ''
    try {
        Wait-Until 'the service principal to sign in and see the subscription' 5 {
            $login = Invoke-Az @('login', '--service-principal', '--username', $Cfg.ClientId, "--password=$($Cfg.ClientSecret)",
                                 '--tenant', $Cfg.TenantId, '--allow-no-subscriptions', '--output', 'none') `
                               -Display 'az login --service-principal' -AllowFailure
            if ($login.ExitCode -ne 0) { $script:LoginError = $login.Err; return }
            $set = Invoke-Az @('account', 'set', '--subscription', $Cfg.SubscriptionId) -AllowFailure
            if ($set.ExitCode -ne 0) { $script:LoginError = $set.Err; return }
            'signed in'
        } 20 | Out-Null
    } catch {
        throw "$($_.Exception.Message) Last error: $(Limit-Text $script:LoginError 300)"
    }
    $script:SpObjectId = Get-TokenObjectId
    $Lab.servicePrincipalObjectId = $SpObjectId
    return ("Signed in as the cloud subscription's service principal $($Cfg.ClientId) (object ID $SpObjectId) " +
            "to subscription $($Cfg.SubscriptionId)")
}

function Initialize-ResourceGroup {
    $groupLocation = Get-AzText @('group', 'show', '--name', $RG, '--query', 'location')
    if (-not $groupLocation) {
        $who = if ($Manual) { 'Your Azure CLI sign-in' } else { 'The service principal' }
        throw "$who can't read resource group $RG."
    }
    if (-not $Manual) {
        # The resource template's location parameter sets the region of the lab's resources: the resource group's, unless
        # the lab profile sets the parameter. The template's outputs give the region that it used.
        $Lab.location = $groupLocation
        if ($AutomaticRegions -notcontains $groupLocation) {
            return ("Resource group $RG in $groupLocation, where AKS Automatic isn't generally available, so the resource template " +
                    "needs its location parameter set to a region that has it, unless $groupLocation has it now")
        }
        return "Resource group $RG in $groupLocation"
    }
    # A manual run deploys the embedded resource template to this region, if the resource group has no deployment of it.
    if ($Cfg.Location) {
        $Lab.location = ([string]$Cfg.Location).Replace(' ', '').ToLowerInvariant()
    } elseif ($AutomaticRegions -contains $groupLocation) {
        $Lab.location = $groupLocation
    } elseif (@(Get-TemplateDeployments | Where-Object { Test-TemplateOutputs $_ }).Count -gt 0) {
        # The resource group already has the template's deployment, whose outputs give the region.
        $Lab.location = $groupLocation
    } else {
        # The resources can be in another region than their resource group, if the access control policy allows it.
        $nearby = [string]$NearbyAutomaticRegion[$groupLocation]
        $problem = "AKS Automatic isn't generally available in $groupLocation, the resource group's region."
        $example = if ($nearby) { ", such as $nearby" } else { '' }
        Write-Host ("$problem The lab's resources can go to another region, if the lab's access control policy allows it. To " +
                    "launch labs in a region that has AKS Automatic$example, set the resource group's Override Region in the lab " +
                    "profile's Cloud tab.")
        $default = if ($nearby) { " [$nearby]" } else { '' }
        $answer = [string](Read-Host "Region for the lab's resources$default")
        $chosen = if ($answer.Trim()) { $answer.Trim().Replace(' ', '').ToLowerInvariant() } else { $nearby }
        if (-not $chosen) { throw "$problem No region was chosen." }
        $Lab.location = $chosen
    }
    return "Resource group $RG in $groupLocation. If this run deploys the resource template, the lab's resources go to $($Lab.location)."
}

function Test-Permission($Permissions, [string]$Action) {
    # Whether one of your role assignments allows the action without excluding it, as Azure RBAC decides.
    foreach ($entry in @($Permissions)) {
        $allowed = @(@($entry.actions) | Where-Object { $_ -and $Action -like $_ }).Count -gt 0
        $excluded = @(@($entry.notActions) | Where-Object { $_ -and $Action -like $_ }).Count -gt 0
        if ($allowed -and -not $excluded) { return $true }
    }
    return $false
}

function Test-ManualAccess {
    # A manual run deploys as you, so you need to create the lab's resources and assign its roles in the resource group.
    # Azure reports your effective permissions there, from every role and group, including custom roles.
    $groupId = Get-AzText @('group', 'show', '--name', $RG, '--query', 'id')
    $roles = @(Get-AzJson @('role', 'assignment', 'list', '--scope', $groupId, '--include-inherited', '--fill-principal-name', 'false',
                            '--query', "[?principalId=='$SpObjectId'].roleDefinitionName") -AllowFailure | Select-Object -Unique)
    $roleText = if ($roles.Count -gt 0) { $roles -join ', ' } else { 'none visible' }
    $answer = Get-AzJson @('rest', '--method', 'get', '--url',
                           "https://management.azure.com$groupId/providers/Microsoft.Authorization/permissions?api-version=2022-04-01") -AllowFailure
    if (-not $answer) { return "Couldn't read your permissions on $RG, so the next steps find out. Your roles there: $roleText." }
    $required = 'Microsoft.Authorization/roleAssignments/write', 'Microsoft.ContainerService/managedClusters/write',
                'Microsoft.ContainerRegistry/registries/write', 'Microsoft.Storage/storageAccounts/write',
                'Microsoft.ManagedIdentity/userAssignedIdentities/write',
                'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write',
                'Microsoft.OperationalInsights/workspaces/write', 'Microsoft.Monitor/accounts/write', 'Microsoft.Insights/components/write',
                'Microsoft.Insights/dataCollectionEndpoints/write', 'Microsoft.Insights/dataCollectionRules/write',
                'Microsoft.Insights/dataCollectionRuleAssociations/write', 'Microsoft.AlertsManagement/prometheusRuleGroups/write',
                'Microsoft.Dashboard/dashboards/write', 'Microsoft.Resources/deployments/write'
    $missing = @($required | Where-Object { -not (Test-Permission $answer.value $_) })
    if ($missing.Count -eq 0) { return "Your roles on $RG ($roleText) can create the lab's resources and assign its roles" }
    $fix = ("In this test lab profile's Cloud tab, give the cloud portal user the Owner role in the resource group's " +
            'Permissions, and launch a new lab. Or add "LAB723 LCA - manual test access.ps1" to the profile, as the LCA runbook ' +
            'describes. If you just launched a lab that has it, wait a few minutes, and run this script again.')
    if ($missing -contains 'Microsoft.Authorization/roleAssignments/write') {
        throw "Your roles on $RG ($roleText) can't assign roles, which the lab needs for kubectl access, AcrPull, and reading the model. $fix"
    }
    throw "Your roles on $RG ($roleText) can't do $($missing -join ', '), which the lab's resource template needs. $fix"
}

function Get-ProviderStates {
    # The registration state of each of the lab's resource providers, or '' where it can't be read. One call.
    $list = @(Get-AzJson @('provider', 'list', '--query', '[].[namespace, registrationState]') -AllowFailure)
    $states = [ordered]@{}
    foreach ($namespace in $ProviderNamespaces) {
        $entry = $list | Where-Object { $_ -and [string]$_[0] -eq $namespace } | Select-Object -First 1
        $states[$namespace] = if ($entry) { [string]$entry[1] } else { '' }
    }
    return $states
}

function Register-Providers {
    # Each lab in the subscription pool gets a new subscription, which may not have these providers registered. The GPU
    # preview feature's registration starts here, because it can take 15 minutes. Complete-GpuFeature finishes it near the end.
    if ($Manual) {
        # Each lab in the pool gets a new subscription with nothing registered. Register what's missing as your account, and
        # wait for registrations in progress before the resource template needs them. If your account can't register them,
        # the manual test access LCA does, as the service principal.
        $states = Get-ProviderStates
        $Lab.gpuFeatureState = Get-GpuFeatureState
        $feature = "ManagedGPUExperiencePreview: $($Lab.gpuFeatureState)"
        if ($Lab.gpuFeatureState -in 'NotRegistered', 'Unregistered') {
            # It can take 15 minutes. Complete-GpuFeature waits for it near the end, and then applies it.
            $result = Invoke-Az @('feature', 'register', '--namespace', 'Microsoft.ContainerService', '--name', 'ManagedGPUExperiencePreview',
                                  '--output', 'none') -AllowFailure
            if ($result.ExitCode -eq 0) {
                $Lab.gpuFeatureState = 'Registering'
                $feature = 'ManagedGPUExperiencePreview: Registering'
            } else {
                $feature += ". Your account couldn't register it. The manual test access LCA does, as the service principal"
            }
        }
        if (@($states.Values | Where-Object { $_ }).Count -eq 0) {
            return ("Your account can't read the subscription's resource providers, so the resource template's deployment finds " +
                    "out if one is missing. $feature")
        }
        foreach ($namespace in @($states.Keys | Where-Object { $states[$_] -in 'NotRegistered', 'Unregistered' })) {
            $null = Invoke-Az @('provider', 'register', '--namespace', $namespace, '--output', 'none') -AllowFailure
        }
        $deadline = (Get-Date).AddMinutes(10)
        $polls = 0
        while ($true) {
            $states = Get-ProviderStates
            $notReady = @($states.Keys | Where-Object { $states[$_] -and $states[$_] -ne 'Registered' })
            $registering = @($notReady | Where-Object { $states[$_] -eq 'Registering' })
            if ($registering.Count -eq 0 -or (Get-Date) -gt $deadline) { break }
            if ($polls % 4 -eq 0) { Write-Log "  Waiting for $($registering -join ', ') to finish registering" }
            $polls++
            Start-Sleep -Seconds 15
        }
        # The resource template and the lab need all of them, now that the template creates the dashboard too.
        $blocking = @($notReady)
        if ($blocking.Count -gt 0) {
            if ($registering.Count -gt 0) {
                throw "Still registering after 10 minutes: $($registering -join ', '). Run this script again in a few minutes."
            }
            throw ("The subscription isn't registered to use $($blocking -join ', '), which the lab needs, and your account can't " +
                   'register them. In this subscription pool, each lab gets its own subscription. Add "LAB723 LCA - manual test ' +
                   'access.ps1" to the test lab profile, which registers them as the service principal, and launch a new lab. If ' +
                   "the lab already has it, wait for it to finish, and run this script again: its result is in the lab's life cycle action log.")
        }
        $detail = 'The resource providers are registered'
        return "$detail. $feature"
    }
    $missing = @($ProviderNamespaces | Where-Object {
        (Get-AzText @('provider', 'show', '--namespace', $_, '--query', 'registrationState') -AllowFailure) -ne 'Registered' })
    foreach ($namespace in $missing) {
        Invoke-Az @('provider', 'register', '--namespace', $namespace, '--output', 'none') | Out-Null
    }
    if ($missing.Count -gt 0) {
        Wait-Until "resource providers $($missing -join ', ') to be registered" 10 {
            $pending = @($missing | Where-Object {
                (Get-AzText @('provider', 'show', '--namespace', $_, '--query', 'registrationState') -AllowFailure) -ne 'Registered' })
            if ($pending.Count -eq 0) { 'registered' }
        } 15 | Out-Null
    }
    $feature = Get-GpuFeatureState
    if ($feature -in 'NotRegistered', 'Unregistered') {
        Invoke-Az @('feature', 'register', '--namespace', 'Microsoft.ContainerService', '--name', 'ManagedGPUExperiencePreview',
                    '--output', 'none') | Out-Null
        $feature = 'Registering'
    }
    $Lab.gpuFeatureState = $feature
    $providers = if ($missing.Count -gt 0) { "Registered $($missing -join ', ')" } else { 'The resource providers were already registered' }
    return "$providers. ManagedGPUExperiencePreview: $feature"
}

function Complete-GpuFeature {
    # Waits for the registration that Register-Providers started, and then registers the provider again, which
    # applies the feature to AKS.
    if ($Manual) {
        # Register-Providers started the registration as your account, or the manual test access LCA did, as the service
        # principal. Wait for it, and then register Microsoft.ContainerService again, which applies the feature to AKS.
        $state = Get-GpuFeatureState
        if ($state -in 'Registering', 'Pending') {
            Write-Log '  Waiting up to 10 minutes for ManagedGPUExperiencePreview to finish registering'
            $deadline = (Get-Date).AddMinutes(10)
            while (($state -in 'Registering', 'Pending') -and ((Get-Date) -lt $deadline)) {
                Start-Sleep -Seconds 30
                $state = Get-GpuFeatureState
            }
        }
        $Lab.gpuFeatureState = $state
        $byHand = ('To finish later, wait until "az feature show --namespace Microsoft.ContainerService --name ManagedGPUExperiencePreview ' +
                   '--query properties.state" shows Registered, and then run "az provider register --namespace Microsoft.ContainerService".')
        switch ($state) {
            'Registered' {
                $result = Invoke-Az @('provider', 'register', '--namespace', 'Microsoft.ContainerService', '--output', 'none') -AllowFailure
                if ($result.ExitCode -eq 0) {
                    return 'ManagedGPUExperiencePreview is registered, and Microsoft.ContainerService was registered again to apply it'
                }
                throw ("ManagedGPUExperiencePreview is registered, but your account couldn't register Microsoft.ContainerService " +
                       'again, which applies it. The manual test access LCA does that, as the service principal.')
            }
            'NotFound' { return "This subscription doesn't offer ManagedGPUExperiencePreview. The readiness gate warns about it." }
            'Unknown'  { throw "Your account can't read the ManagedGPUExperiencePreview feature. The manual test access LCA registers it, as the service principal." }
            default    { throw "ManagedGPUExperiencePreview is $state. GPU nodes need it registered, which can take 15 minutes. $byHand" }
        }
    }
    $state = Wait-Until 'ManagedGPUExperiencePreview to finish registering' 10 {
        $current = Get-GpuFeatureState
        if ($current -notin 'Registering', 'Pending') { $current }
    } 30
    $Lab.gpuFeatureState = $state
    switch ($state) {
        'Registered' {
            Invoke-Az @('provider', 'register', '--namespace', 'Microsoft.ContainerService', '--output', 'none') | Out-Null
            return 'ManagedGPUExperiencePreview is registered, and Microsoft.ContainerService was registered again to apply it'
        }
        'NotFound' {
            return "This subscription doesn't offer ManagedGPUExperiencePreview, so there's nothing to register. The readiness gate warns about it."
        }
        default { throw "The ManagedGPUExperiencePreview state is $state. GPU nodes need it registered." }
    }
}
function Resolve-PortalUser {
    # The service principal looks up the portal user in Microsoft Entra ID. If it can't, the fallback is the only
    # user with a role on the resource group, where Skillable assigns the portal user's role. The Role assignments
    # step assigns the portal user's roles. In a manual run, you're the portal user.
    if ($Manual) {
        $Lab.portalUserObjectId = $SpObjectId
        return "$($Cfg.PortalUser): object ID $SpObjectId. You're the portal user and the deployer in a manual run."
    }
    $userId = ''
    if (Test-Resolved $Cfg.PortalUser) {
        $userId = Get-AzText @('ad', 'user', 'show', '--id', $Cfg.PortalUser, '--query', 'id') -AllowFailure
    }
    if (-not $userId) {
        $users = @(Get-AzJson @('role', 'assignment', 'list', '--resource-group', $RG, '--fill-principal-name', 'false',
                                '--query', "[?principalType=='User'].principalId") -AllowFailure | Select-Object -Unique)
        if ($users.Count -ne 1) {
            throw ("Couldn't find the object ID of the portal user, so its roles can't be assigned. Check that " +
                   "PortalUser names the profile's cloud portal user. Users with a role on the resource group: $($users.Count).")
        }
        $userId = [string]$users[0]
    }
    $Lab.portalUserObjectId = $userId
    return "$($Cfg.PortalUser): object ID $userId"
}

function Expand-ResourceTemplate {
    # Writes the embedded resource template, which only a manual run deploys, after checking its hash.
    if (-not $TemplateBundleHash) {
        throw 'This script has no embedded resource template. Run "LAB723 resource template - build.ps1", and paste the whole script.'
    }
    $packed = [Convert]::FromBase64String(($TemplateBundle -replace '\s', ''))
    $gzip = New-Object IO.Compression.GZipStream((New-Object IO.MemoryStream(, $packed)), [IO.Compression.CompressionMode]::Decompress)
    $buffer = New-Object IO.MemoryStream
    $gzip.CopyTo($buffer)
    $gzip.Dispose()
    $bytes = $buffer.ToArray()
    $sha = [Security.Cryptography.SHA256]::Create()
    if ([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') -ne $TemplateBundleHash) {
        throw 'The embedded resource template is damaged. Run "LAB723 resource template - build.ps1" again, and paste the whole script.'
    }
    [IO.File]::WriteAllBytes($TemplatePath, $bytes)
    return $TemplatePath
}

function Get-TemplateDeployments {
    # The resource group's deployments, newest first. A deployment of the LAB723 resource template has its marker output.
    $query = '[].{name: name, state: properties.provisioningState, timestamp: properties.timestamp, outputs: properties.outputs, error: properties.error}'
    $list = @(Get-AzJson @('deployment', 'group', 'list', '--resource-group', $RG, '--query', $query) -AllowFailure | Where-Object { $_ })
    # Compare instants. PowerShell 7 reads the timestamps as DateTime values, and Windows PowerShell as strings.
    return @($list | Sort-Object -Descending -Property {
        $when = [DateTimeOffset]::MinValue
        if ($_.timestamp) { try { $when = [DateTimeOffset]$_.timestamp } catch { } }
        $when
    })
}

function Test-TemplateOutputs($Deployment) {
    return ([string]$Deployment.state -eq 'Succeeded' -and $null -ne $Deployment.outputs -and $null -ne $Deployment.outputs.$TemplateMarker)
}

function Test-InProgress($Deployment) {
    $state = [string]$Deployment.state
    return ($state -and $state -notin 'Succeeded', 'Failed', 'Canceled', 'Deleted', 'Deleting')
}

function Get-DeploymentProgress([string]$Name) {
    $states = @(Get-AzJson @('deployment', 'operation', 'group', 'list', '--resource-group', $RG, '--name', $Name,
                             '--query', '[].properties.provisioningState') -AllowFailure)
    return "$(@($states | Where-Object { $_ -eq 'Succeeded' }).Count) resources deployed so far"
}

function Format-AzureError($Err) {
    # An Azure error and its details, which can nest, on one line.
    if (-not $Err) { return '' }
    if ($Err -is [string]) { return $Err }
    $inner = if ($Err.error) { $Err.error } else { $Err }
    $parts = @("$($inner.code): $($inner.message)") + @(@($inner.details) | Where-Object { $_ } | ForEach-Object { Format-AzureError $_ })
    return (@($parts | Where-Object { $_ -and $_.Trim() -ne ':' }) -join ' ')
}

function Get-DeploymentError($Deployment) {
    # The failed operations say what went wrong. The deployment's own error often says only to read them.
    $query = ("[?properties.provisioningState=='Failed'].{type: properties.targetResource.resourceType, " +
              'name: properties.targetResource.resourceName, status: properties.statusMessage}')
    $messages = @(foreach ($operation in @(Get-AzJson @('deployment', 'operation', 'group', 'list', '--resource-group', $RG,
                                                        '--name', [string]$Deployment.name, '--query', $query) -AllowFailure)) {
        if (-not $operation) { continue }
        $what = if ($operation.name) { "$($operation.type) $($operation.name)" } else { 'An operation' }
        "$what failed. $(Format-AzureError $operation.status)"
    })
    if ($messages.Count -eq 0) { $messages = @(@(Format-AzureError $Deployment.error) | Where-Object { $_ }) }
    $text = if ($messages.Count -gt 0) { Limit-Text ($messages -join ' | ') 1500 } else { 'Azure gave no reason.' }
    $hint = ''
    if ($text -match 'MissingSubscriptionRegistration|not registered to use namespace|NoRegisteredProviderFound') {
        $hint = (' A resource provider that the template needs wasn''t registered in the subscription yet. The resource providers ' +
                 'LCA and this action register them, so a new lab, or another deployment of the template, works.')
    } elseif ($text -match 'RequestDisallowedByPolicy') {
        $hint = ' The lab profile''s access control policy blocks a resource type, region, or VM size that the template needs.'
    } elseif ($text -match 'AuthorizationFailed|roleAssignments/write') {
        $hint = ' The identity that deployed the template can''t do everything that the template needs, such as assigning roles.'
    }
    return "$text$hint"
}

function Use-TemplateNames {
    # The resource template names the model container and the dashboard. A deployed template's names win over the settings,
    # which only a manual run's deployment uses. A template without a dashboard has an empty name, which the gate skips.
    if ($Lab.modelContainerName) { $Cfg.ModelContainer = [string]$Lab.modelContainerName }
    if ($null -ne $Lab.dashboardName) { $Cfg.DashboardName = [string]$Lab.dashboardName }
}

function Set-LabFromTemplate($Deployment) {
    $outputs = $Deployment.outputs
    function Get-Output([string]$Name) {
        $entry = $outputs.$Name
        if ($null -eq $entry) {
            throw "Resource template deployment $($Deployment.name) has no output named $Name. Deploy the current LAB723 resource template."
        }
        return [string]$entry.value
    }
    $Lab.templateDeployment   = [string]$Deployment.name
    $Lab.templateVersion      = Get-Output $TemplateMarker
    $Lab.location             = Get-Output 'location'
    $Lab.clusterName          = Get-Output 'cluster_name'
    $Lab.clusterId            = Get-Output 'cluster_id'
    $Lab.kubernetesVersion    = Get-Output 'kubernetes_version'
    $Lab.kubeletObjectId      = Get-Output 'kubelet_object_id'
    $Lab.oidcIssuer           = Get-Output 'oidc_issuer_url'
    $Lab.registryName         = Get-Output 'registry_name'
    $Lab.registryId           = Get-Output 'registry_id'
    $Lab.registryLoginServer  = Get-Output 'registry_login_server'
    $Lab.storageName          = Get-Output 'storage_account_name'
    $Lab.storageId            = Get-Output 'storage_account_id'
    $Lab.modelContainerName   = Get-Output 'model_container_name'
    $Lab.modelContainerScope  = Get-Output 'model_container_scope'
    $Lab.identityName         = Get-Output 'identity_name'
    $Lab.identityClientId     = Get-Output 'identity_client_id'
    $Lab.identityPrincipalId  = Get-Output 'identity_principal_id'
    $Lab.logAnalyticsName     = Get-Output 'log_analytics_workspace_name'
    $Lab.logAnalyticsId       = Get-Output 'log_analytics_workspace_id'
    $Lab.monitorWorkspaceName = Get-Output 'monitor_workspace_name'
    $Lab.monitorWorkspaceId   = Get-Output 'monitor_workspace_id'
    $Lab.prometheusEndpoint   = Get-Output 'prometheus_query_endpoint'
    $Lab.appInsightsName      = Get-Output 'app_insights_name'
    $Lab.appInsightsId        = Get-Output 'app_insights_id'
    $Lab.dashboardName        = Get-Output 'dashboard_name'
    $Lab.templateDeployerId   = Get-Output 'deployer_object_id'
    $portalUser = Get-Output 'portal_user_object_id'
    if ($portalUser) { $Lab.portalUserObjectId = $portalUser }
    Use-TemplateNames
    if (-not $Lab.oidcIssuer) { throw "Cluster $($Lab.clusterName) has no OIDC issuer, so workload identity can't work." }
    # The template doesn't return the Application Insights connection string, so that the deployment's history doesn't show it.
    $script:AppInsightsConnection = Get-AzText @('resource', 'show', '--ids', $Lab.appInsightsId, '--api-version', '2020-02-02',
                                                 '--query', 'properties.ConnectionString') -AllowFailure
    if (-not $AppInsightsConnection) { throw "Couldn't read the connection string of Application Insights $($Lab.appInsightsName)." }
    # Confirm what the template asked for from the cluster itself.
    $cluster = Get-AzJson @('aks', 'show', '--resource-group', $RG, '--name', $Lab.clusterName) -AllowFailure
    if (-not $cluster -or $cluster.provisioningState -ne 'Succeeded') {
        $state = if ($cluster) { $cluster.provisioningState } else { 'unreadable' }
        throw "Cluster $($Lab.clusterName) isn't ready. Provisioning state: $state."
    }
    $Lab.clusterSku = [string]$cluster.sku.name
    $Lab.prometheusEnabled = [bool]$cluster.azureMonitorProfile.metrics.enabled
}

function Start-TemplateDeployment([string]$Name) {
    # A manual run deploys the embedded template, as you, when the resource group has no deployment of it. You're the deployer
    # and the portal user, so the template gives you the deployer's roles, and the portal user's other role.
    $template = Expand-ResourceTemplate
    # An empty dashboardName turns the dashboard off, so it's always passed.
    $parameters = [ordered]@{ deployerPrincipalType = @{ value = 'User' }; dashboardName = @{ value = [string]$Cfg.DashboardName } }
    $values = [ordered]@{
        location           = [string]$Lab.location
        kubernetesVersion  = [string]$Cfg.KubernetesVersion
        modelContainerName = [string]$Cfg.ModelContainer
        portalUserObjectId = [string]$Lab.portalUserObjectId
    }
    foreach ($key in $values.Keys) { if ($values[$key]) { $parameters[$key] = @{ value = $values[$key] } } }
    $file = Join-Path $LcaDir 'lab723-resource-template.parameters.json'
    $document = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $parameters
    }
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $document -Depth 5), $Utf8)
    Write-Log "  Deploying the embedded LAB723 resource template to $RG as deployment $Name, as you. It takes 10 to 20 minutes."
    Invoke-Az @('deployment', 'group', 'create', '--resource-group', $RG, '--name', $Name, '--template-file', $template,
                '--parameters', "@$file", '--no-wait', '--output', 'none') -Display 'az deployment group create (LAB723 resource template)' |
        Out-Null
    return $Name
}

function Set-AzureResources {
    # Skillable deploys the LAB723 resource template to the resource group before this action runs, unless the lab profile
    # deploys it in the background. This step waits for a deployment that's still running, and then reads the outputs of the
    # newest deployment of the template. A manual run deploys the embedded copy of the template, as you, if the resource group
    # has no deployment of it.
    $named = ([string]$Cfg.TemplateDeployment).Trim()
    $waitMinutes = [Math]::Max(5, [int]$Cfg.TemplateWaitMinutes)
    $deadline = (Get-Date).AddMinutes($waitMinutes)
    $appearBy = (Get-Date).AddMinutes(5)   # How long to wait for a deployment to appear, when the resource group has none
    $deployedName = ''
    $polls = 0
    while ($true) {
        # Once this run has started its own deployment, only that one counts, so an earlier failure under another name
        # can't stop it.
        $candidates = @(Get-TemplateDeployments | Where-Object {
            if ($deployedName) { $_.name -eq $deployedName } else { -not $named -or $_.name -eq $named } })
        # A finished deployment of the template wins over one that's still running. A Skillable lab's resource group has one,
        # and another deployment of the template there has the same names and outputs.
        $ready = @($candidates | Where-Object { Test-TemplateOutputs $_ }) | Select-Object -First 1
        if ($ready) { break }
        $busy = @($candidates | Where-Object { Test-InProgress $_ }) | Select-Object -First 1
        if ($busy) {
            if ((Get-Date) -gt $deadline) {
                throw ("Deployment $($busy.name) in $RG is still $($busy.state) after $waitMinutes minutes. Run this action again " +
                       'when it finishes, or raise TemplateWaitMinutes.')
            }
            if ($polls % 4 -eq 0) { Write-Log "  Waiting for deployment $($busy.name) ($($busy.state)): $(Get-DeploymentProgress $busy.name)" }
            $polls++
            Start-Sleep -Seconds 30
            continue
        }
        $failed = @($candidates | Where-Object { [string]$_.state -in 'Failed', 'Canceled' }) | Select-Object -First 1
        if ($Manual -and -not $deployedName) {
            if ($failed) { Write-Log "  Deployment $($failed.name) is $($failed.state). $(Get-DeploymentError $failed) This run deploys the template again." }
            # A new name each time, so that the list can't show this name's earlier failure as this deployment's.
            $deployedName = Start-TemplateDeployment $(if ($named) { $named } else { 'lab723-resources-{0:yyyyMMdd-HHmmss}' -f (Get-Date) })
            $deadline = (Get-Date).AddMinutes([Math]::Max($waitMinutes, 45))
            $appearBy = (Get-Date).AddMinutes(5)
            continue
        }
        if ($failed) {
            throw "The LAB723 resource template's deployment $($failed.name) is $($failed.state). $(Get-DeploymentError $failed)"
        }
        if ((Get-Date) -gt $appearBy) {
            $which = if ($named) { "named $named" } else { 'with the outputs of the LAB723 resource template' }
            throw ("Resource group $RG has no deployment $which. In the lab profile's Cloud tab, attach the LAB723 resource template " +
                   'to the resource group, as "LAB723 resource template - Skillable setup.md" describes, and launch a new lab.')
        }
        if ($polls % 4 -eq 0) { Write-Log "  Waiting for the LAB723 resource template's deployment to appear in $RG" }
        $polls++
        Start-Sleep -Seconds 30
    }
    Set-LabFromTemplate $ready
    $how = if ($deployedName) { "Deployed the embedded resource template as $($ready.name)" } else { "Resource template deployment $($ready.name)" }
    return ("$how (template version $($Lab.templateVersion)): cluster $($Lab.clusterName) ($($Lab.clusterSku), Kubernetes " +
            "$($Lab.kubernetesVersion)) in $($Lab.location), registry $($Lab.registryLoginServer), storage $($Lab.storageName)")
}

function Set-RoleAssignments {
    # The resource template assigns roles to the identity that deploys it, and to the portal user only if it gets the user's
    # object ID, which Skillable can't give it. So this step assigns the portal user's roles, and the roles that this action
    # needs, in case Skillable deployed the template as another identity. Role assignments that exist are left as they are.
    $mine = if ($Manual) { 'you' } else { 'the service principal' }
    $myType = if ($Manual) { 'User' } else { 'ServicePrincipal' }
    $wanted = New-Object System.Collections.Generic.List[object]
    foreach ($pair in @(@('Azure Kubernetes Service RBAC Cluster Admin', $Lab.clusterId), @('Monitoring Data Reader', $Lab.monitorWorkspaceId),
                        @('Storage Blob Data Contributor', $Lab.modelContainerScope))) {
        $wanted.Add([pscustomobject]@{ Who = $mine; Id = [string]$SpObjectId; Type = $myType; Role = $pair[0]; Scope = [string]$pair[1] })
    }
    $userId = [string]$Lab.portalUserObjectId
    if ($userId) {
        foreach ($pair in @(@('Azure Kubernetes Service RBAC Cluster Admin', $Lab.clusterId), @('Monitoring Data Reader', $Lab.monitorWorkspaceId),
                            @('Log Analytics Reader', $Lab.logAnalyticsId))) {
            # In a manual run, you're the portal user too, and already have two of these.
            if (@($wanted | Where-Object { $_.Id -eq $userId -and $_.Role -eq $pair[0] -and $_.Scope -eq [string]$pair[1] }).Count -gt 0) { continue }
            $wanted.Add([pscustomobject]@{ Who = 'the portal user'; Id = $userId; Type = 'User'; Role = $pair[0]; Scope = [string]$pair[1] })
        }
    }
    $added = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($item in $wanted) {
        if (-not $item.Id -or -not $item.Scope) { $failed.Add("$($item.Role) for $($item.Who) (no object ID or scope)"); continue }
        if (Test-RoleAssignment $item.Id $item.Role $item.Scope) { continue }
        $result = Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $item.Id, '--assignee-principal-type', $item.Type,
                              '--role', $item.Role, '--scope', $item.Scope, '--output', 'none') `
                            -Display "az role assignment create ($($item.Role) for $($item.Who))" -AllowFailure
        if ($result.ExitCode -eq 0 -or $result.Err -match 'RoleAssignmentExists|already exists') {
            $added.Add("$($item.Role) for $($item.Who)")
        } else {
            $failed.Add("$($item.Role) for $($item.Who) ($(Limit-Text (Get-ErrorText $result.Err) 300))")
        }
    }
    $note = if ($userId) { '' } else { " The portal user's object ID is unknown, so its roles weren't assigned: see the Portal user step." }
    if ($failed.Count -gt 0) { throw "Couldn't assign $($failed -join '; ').$note" }
    $done = if ($added.Count -gt 0) { "Assigned $($added -join ', ')" } else { "All $($wanted.Count) role assignments were already in place" }
    return "$done.$note"
}

function Get-LabContent {
    # The lab content repository at the ContentVersion tag: a shallow clone, or GitHub's archive of the tag if git can't
    # clone it. Later steps take the lab files and the model's download list from it.
    $script:ContentDir = ''
    $url = ([string]$Cfg.ContentRepoUrl).Trim().TrimEnd('/') -replace '\.git$', ''
    $version = ([string]$Cfg.ContentVersion).Trim()
    if (-not $url -or -not $version) {
        throw 'ContentRepoUrl or ContentVersion is empty, so the lab files and the model must already be in the VM.'
    }
    $target = Join-Path $LcaDir 'content'
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $target) { $target = Join-Path $LcaDir ('content-{0:yyyyMMdd-HHmmss}' -f (Get-Date)) }
    $env:GIT_TERMINAL_PROMPT = '0'   # A public repository needs no credentials, so never wait for them
    $git = @((Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
             'C:\Program Files\Git\cmd\git.exe' | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1
    $how = ''
    if ($git) {
        $clone = Invoke-Tool -FilePath $git -Display "git clone $url" -AllowFailure -Arguments @(
            '-c', 'credential.helper=', '-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1',
            '--branch', $version, "$url.git", $target)
        if ($clone.ExitCode -eq 0) {
            $commit = (Invoke-Tool -FilePath $git -Display 'git rev-parse' -AllowFailure -Arguments @(
                '-c', 'safe.directory=*', '-C', $target, 'rev-parse', '--short', 'HEAD')).Out.Trim()
            $how = "git clone, commit $commit"
        } else {
            Write-Log "  git couldn't clone $url at $version, so this downloads the tag's archive. $(Limit-Text $clone.Err 300)"
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $how) {
        $zip = Join-Path $LcaDir 'content.zip'
        $staging = Join-Path $LcaDir 'content-staging'
        Remove-Item -LiteralPath $zip, $staging -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri "$url/archive/refs/tags/$version.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
        $top = @(Get-ChildItem -LiteralPath $staging)
        if ($top.Count -ne 1 -or -not $top[0].PSIsContainer) { throw "The archive of $url at $version doesn't have one top folder." }
        Move-Item -LiteralPath $top[0].FullName -Destination $target
        Remove-Item -LiteralPath $zip, $staging -Recurse -Force -ErrorAction SilentlyContinue
        $how = 'archive download'
    }
    $missing = @('labfiles\02-deploy\inference-deployment.yaml', 'model\model.json' |
                 Where-Object { -not (Test-Path -LiteralPath (Join-Path $target $_)) })
    if ($missing.Count -gt 0) { throw "$url at $version doesn't have $($missing -join ', ')." }
    $script:ContentDir = $target
    $Lab.content = "$url at $version"
    return "$url at $version ($how) in $target"
}

function Set-Images {
    $repositories = [ordered]@{
        'inference' = 'lab723/inference'; 'inference-gpu' = 'lab723/inference-gpu'; 'lab-client' = 'lab723/lab-client'
        'loadgen' = 'lab723/loadgen'; 'ray' = 'lab723/ray'; 'notebook' = 'lab723/notebook'
    }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($repositories.Keys)) {
        $image = "$($repositories[$key]):$($Cfg.ImageTag)"
        $found = (Invoke-Az @('acr', 'repository', 'show', '--name', $Lab.registryName, '--image', $image) -AllowFailure).ExitCode -eq 0
        if (-not $found -and $Cfg.SourceRegistry) {
            $import = @('acr', 'import', '--name', $Lab.registryName, '--source', "$($Cfg.SourceRegistry)/$image", '--image', $image)
            if ($Cfg.SourceUsername) { $import += @('--username', [string]$Cfg.SourceUsername, "--password=$($Cfg.SourcePassword)") }
            $result = Invoke-Az $import -Display "az acr import $image" -AllowFailure
            $found = $result.ExitCode -eq 0
            if (-not $found) { Write-Log "  Couldn't import ${image}: $(Limit-Text $result.Err 300)" }
        }
        $Images[$key] = if ($found) { "$($Lab.registryLoginServer)/$image" } else { '' }
        if (-not $found) { $missing.Add($key) }
    }
    if (-not $Images['ray']) { $Images['ray'] = [string]$Cfg.RayFallbackImage }
    $Lab.images = $Images
    if ($missing.Count -gt 0) {
        throw ("Not in $($Lab.registryLoginServer) with tag $($Cfg.ImageTag): $($missing -join ', '). Check that the content " +
               "repository's workflow published them for $($Cfg.ContentVersion) to $($Cfg.SourceRegistry), and that the packages " +
               "are public. Workloads that need them aren't deployed. Ray uses $($Images['ray']).")
    }
    return "All six lab images are in $($Lab.registryLoginServer) with tag $($Cfg.ImageTag)"
}

function Get-ModelFiles([string]$Folder) {
    # Downloads the files that model\model.json in the content repository lists, unless the folder already has them, and
    # checks each file's SHA-256 hash. Returns how many it downloaded.
    $manifest = Get-Content -LiteralPath (Join-Path $ContentDir 'model\model.json') -Raw | ConvertFrom-Json
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    Get-ChildItem -LiteralPath $Folder -Filter '*.partial' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $downloaded = 0
    foreach ($file in @($manifest.files)) {
        $target = Join-Path $Folder ([string]$file.name)
        $expected = ([string]$file.sha256).ToUpperInvariant()
        if ((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $expected) { continue }
        $partial = "$target.partial"
        if (Test-Path -LiteralPath $curl) {
            Invoke-Tool -FilePath $curl -Display "curl $($file.name)" -Arguments @(
                '--fail', '--location', '--silent', '--show-error', '--retry', '5', '--retry-delay', '5',
                '--output', $partial, [string]$file.url) | Out-Null
        } else {
            Invoke-WebRequest -Uri ([string]$file.url) -OutFile $partial -UseBasicParsing
        }
        $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $partial -Force
            throw "$($file.name) from $($file.url) has SHA-256 $actual, not $expected."
        }
        Move-Item -LiteralPath $partial -Destination $target -Force
        $downloaded++
    }
    return $downloaded
}

function Publish-Model {
    $source = [string]$Cfg.ModelSourcePath
    $fetched = ''
    if ($ContentDir -and $source) {
        try {
            $count = Get-ModelFiles $source
        } catch {
            # A later run can't reach the model's host, but an earlier one uploaded the files.
            if ((Get-BlobCount) -gt 0) {
                return "Couldn't check the model files ($($_.Exception.Message)), but the $($Cfg.ModelContainer) container already has them."
            }
            throw
        }
        $fetched = if ($count -gt 0) { "Downloaded $count model files, and checked their SHA-256 hashes. " }
                   else { 'The model files in the VM match model\model.json. ' }
    }
    $hasFiles = $source -and (Test-Path -LiteralPath $source) -and
                [bool](Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $hasFiles) {
        $count = Get-BlobCount
        if ($count -gt 0) { return "The $($Cfg.ModelContainer) container already has model files." }
        throw "No model files: $source doesn't exist or is empty, and the $($Cfg.ModelContainer) container is empty."
    }
    # Data-plane role assignments can take a few minutes to apply, so retry the upload.
    Wait-Until 'the model upload' 10 {
        $result = Invoke-Az @('storage', 'blob', 'upload-batch', '--account-name', $Lab.storageName, '--destination',
                              $Cfg.ModelContainer, '--source', $source, '--auth-mode', 'login', '--overwrite', 'true',
                              '--output', 'none') -Display 'az storage blob upload-batch' -AllowFailure
        $result.ExitCode -eq 0
    } 30 | Out-Null
    return "${fetched}Uploaded $source to $($Lab.storageName)/$($Cfg.ModelContainer)"
}

# ---------------------------------------------------------------------------------------------
# Kubernetes and lab VM steps
# ---------------------------------------------------------------------------------------------
function Set-Kubeconfig {
    # Exactly one context, the attendee's cluster, in azurecli login mode, as the lab steps expect. The worker reaches the
    # cluster through its own Azure CLI profile, and the attendee through theirs, after they sign in.
    Remove-Item -LiteralPath $Kubeconfig -Force -ErrorAction SilentlyContinue
    Invoke-Az @('aks', 'get-credentials', '--resource-group', $RG, '--name', $Lab.clusterName, '--file', $Kubeconfig,
                '--overwrite-existing', '--output', 'none') | Out-Null
    Invoke-Tool -FilePath $KubeloginExe -Arguments @('convert-kubeconfig', '-l', 'azurecli', '--kubeconfig', $Kubeconfig) `
                -Display 'kubelogin convert-kubeconfig' | Out-Null
    # Azure RBAC for Kubernetes can take a few minutes to apply.
    $nodes = Wait-Until 'Kubernetes access (Azure RBAC role assignments can take a few minutes to apply)' 15 {
        $result = Invoke-Kubectl @('get', 'nodes', '--output', 'name') -AllowFailure
        if ($result.ExitCode -eq 0) { 'nodes:' + @($result.Out -split "`n" | Where-Object { $_.Trim() }).Count } else { $null }
    } 20
    $who = if ($Manual) { 'Your account' } else { 'The service principal' }
    return "kubeconfig for $($Lab.clusterName) in $Kubeconfig (kubelogin azurecli mode). $who sees $($nodes -replace 'nodes:', '') nodes"
}

function Set-AttendeeCli {
    # The attendee signs in to the Azure CLI with their own lab account in Exercise 1. Browser sign-in, rather than the
    # Windows sign-in broker, reuses their Azure portal sign-in in Edge. A service principal sign-in, which an earlier
    # version of this LCA left in the lab user's profile, is removed, because the attendee mustn't get it.
    $saved = $env:AZURE_CONFIG_DIR
    $removed = ''
    try {
        $env:AZURE_CONFIG_DIR = $LabAzureDir
        Invoke-Az @('config', 'set', 'core.enable_broker_on_windows=false', 'core.login_experience_v2=off',
                    'core.collect_telemetry=false', 'core.survey_message=false', 'auto-upgrade.enable=no') | Out-Null
        $account = Get-AzJson @('account', 'show') -AllowFailure
        if ($account -and $account.user.type -eq 'servicePrincipal') {
            Invoke-Az @('account', 'clear') | Out-Null
            $removed = " Removed a service principal sign-in, $($account.user.name)."
            $account = $null
        }
    } finally {
        $env:AZURE_CONFIG_DIR = $saved
    }
    $state = if ($account) { "signed in as $($account.user.name)" } else { 'not signed in' }
    return "The lab user's Azure CLI uses browser sign-in and is $state.$removed The attendee signs in during Exercise 1."
}

function Set-CodeShortcuts {
    # The lab steps expect VS Code to open C:\LabFiles\LAB723. The image's VS Code settings don't restore windows, so a VS
    # Code shortcut without a folder, such as the Start menu's or a taskbar pin, opens an empty window. Give those shortcuts
    # the lab folder, and make sure that the startup shortcut, which opens VS Code at sign-in, exists and has it too. A
    # VS Code shortcut with other arguments opens something else on purpose, so it's left alone.
    if (-not (Test-Path -LiteralPath $CodeExe)) { throw "$CodeExe is missing. Build the image with LAB723 VM image setup.ps1." }
    $root = ([string]$Cfg.LabRoot).TrimEnd('\')
    $folderArgument = '"' + $root + '"'
    $userPrograms = Join-Path $Cfg.LabProfile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'
    $startupLink = Join-Path $userPrograms 'Startup\LAB723 - Visual Studio Code.lnk'
    $places = @($CommonPrograms, $userPrograms, $PublicDesktop, (Join-Path $Cfg.LabProfile 'Desktop'),
                (Join-Path $Cfg.LabProfile 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar') |
              Where-Object { Test-Path -LiteralPath $_ })
    $links = @(if ($places.Count) { Get-ChildItem -LiteralPath $places -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue |
                                    ForEach-Object { $_.FullName } })
    if ($links -notcontains $startupLink) { $links += $startupLink }
    $shell = New-Object -ComObject WScript.Shell
    $changed = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $count = 0
    foreach ($path in $links) {
        $link = $shell.CreateShortcut($path)   # An empty shortcut if the file doesn't exist yet
        $isCode = $link.TargetPath -eq $CodeExe
        if ($path -ne $startupLink -and (-not $isCode -or ($link.Arguments -and $link.Arguments -ne $folderArgument))) { continue }
        if ($isCode -and $link.Arguments -eq $folderArgument -and $link.WorkingDirectory -eq $root) { $count++; continue }
        $place = if ($path -eq $startupLink) { 'startup' } elseif ($path -like '*\User Pinned\TaskBar\*') { 'taskbar' }
                 elseif ($path -like '*\Desktop\*') { 'desktop' } else { 'Start menu' }
        $place += " ($([IO.Path]::GetFileNameWithoutExtension($path)))"
        # One shortcut that can't be saved doesn't keep the others from being updated.
        try {
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            $link.TargetPath = $CodeExe
            $link.Arguments = $folderArgument
            $link.WorkingDirectory = $root
            $link.Save()
            $count++
            $changed.Add($place)
        } catch {
            $failed.Add("$place, $path. $($_.Exception.Message)")
        }
    }
    $updated = if ($changed.Count) { " Updated: $($changed -join ', ')." } else { '' }
    if ($failed.Count) { throw "$count VS Code shortcuts open $root.$updated Couldn't update: $($failed -join ' ')" }
    return "$count VS Code shortcuts open $root, including the startup shortcut that opens it at sign-in.$updated"
}

function Set-ClusterBase {
    Invoke-Apply 'namespaces' $NamespacesYaml
    Invoke-Apply 'lab-settings' (Format-Template $LabSettingsYaml @{
        CLIENT_ID = $Lab.identityClientId; TENANT_ID = $Cfg.TenantId; REGISTRY = $Lab.registryLoginServer
        STORAGE_ACCOUNT = $Lab.storageName; MODEL_CONTAINER = $Cfg.ModelContainer })
    $detail = 'Namespaces ai-lab and ray; ServiceAccount inference with workload identity; ConfigMap lab-environment'
    if ($AppInsightsConnection) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($AppInsightsConnection))
        # The manifest has the connection string, so it's removed even when the apply fails.
        try {
            Invoke-Apply 'appinsights-secret' (Format-Template $AppInsightsSecretYaml @{ CONNECTION_STRING = $encoded })
        } finally {
            Remove-Item -LiteralPath (Join-Path $Manifests 'appinsights-secret.yaml') -Force -ErrorAction SilentlyContinue
        }
        $detail += '; Secret appinsights'
    }
    return $detail
}

function ConvertTo-RequirementJson($Requirement) {
    # One NodePool requirement as JSON. It's built here, because Windows PowerShell's ConvertTo-Json can write an array
    # that came from ConvertFrom-Json as an object with value and Count properties.
    $quote = { param($Text) '"' + (([string]$Text) -replace '\\', '\\' -replace '"', '\"') + '"' }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('"key":' + (& $quote $Requirement.key))
    $parts.Add('"operator":' + (& $quote $Requirement.operator))
    if ($null -ne $Requirement.values) { $parts.Add('"values":[' + ((@($Requirement.values) | ForEach-Object { & $quote $_ }) -join ',') + ']') }
    if ($null -ne $Requirement.minValues) { $parts.Add('"minValues":' + [int]$Requirement.minValues) }
    return '{' + ($parts -join ',') + '}'
}

function Get-PoolSizes($Pool) {
    # The VM sizes that a NodePool's requirements name, or none if they allow any size of its families
    return @(@($Pool.spec.template.spec.requirements) |
             Where-Object { $_ -and $SizeKeys -contains [string]$_.key -and [string]$_.operator -eq 'In' } |
             ForEach-Object { @($_.values) } | Where-Object { $_ } | Select-Object -Unique)
}

function Set-NodePools {
    $nodeClassApi = Get-ServedVersion 'aksnodeclasses.karpenter.azure.com'
    $nodePoolApi = Get-ServedVersion 'nodepools.karpenter.sh'
    if (-not $nodeClassApi -or $nodePoolApi -ne 'karpenter.sh/v1') {
        throw "Node auto-provisioning resources aren't available (AKSNodeClass: '$nodeClassApi', NodePool: '$nodePoolApi')."
    }
    Invoke-Apply 'gpu-nodepool' (Format-Template $GpuPoolYaml @{
        NODECLASS_API = $nodeClassApi; GPU_VM_SIZE = $Cfg.GpuVmSize; GPU_CPU_LIMIT = $Cfg.GpuCpuLimit })
    $detail = "gpu NodePool: $($Cfg.GpuVmSize) only, on-demand, cpu limit $($Cfg.GpuCpuLimit), WhenEmpty after 30s, managed GPU"
    # One merge patch for the default NodePool. It replaces the requirements list, so it keeps every requirement but the sizes.
    $changes = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    if ($Cfg.PatchDefaultNodePool) {
        $changes.Add('"disruption":{"consolidationPolicy":"WhenEmpty","consolidateAfter":"30s"}')
        $notes.Add('WhenEmpty after 30s')
    }
    if ($CpuVmSizes.Count -gt 0) {
        $default = Get-KubeJson @('get', 'nodepools.karpenter.sh', 'default')
        if (-not $default) { throw "$detail. There's no default NodePool to limit to $($CpuVmSizes -join ', ')." }
        $requirements = @(@($default.spec.template.spec.requirements) | Where-Object { $_ -and $SizeKeys -notcontains [string]$_.key } |
                          ForEach-Object { ConvertTo-RequirementJson $_ })
        $requirements += ConvertTo-RequirementJson ([pscustomobject]@{ key = $SizeKeys[0]; operator = 'In'; values = $CpuVmSizes })
        $changes.Add('"template":{"spec":{"requirements":[' + ($requirements -join ',') + ']}}')
        $notes.Add("only $($CpuVmSizes -join ', ')")
    }
    if ($changes.Count -gt 0) {
        $patch = Join-Path $Manifests 'default-nodepool-patch.json'
        [IO.File]::WriteAllText($patch, '{"spec":{' + ($changes -join ',') + '}}', $Utf8)
        $result = Invoke-Kubectl @('patch', 'nodepools.karpenter.sh', 'default', '--type', 'merge', '--patch-file', $patch) -AllowFailure
        if ($result.ExitCode -ne 0) { throw "$detail. Couldn't change the default NodePool. $(Limit-Text $result.Err 300)" }
        $detail += ". default NodePool: $($notes -join ', ')"
    }
    return $detail
}

function Set-ServiceMonitor {
    Invoke-Apply 'servicemonitor' $ServiceMonitorYaml
    return 'ServiceMonitor lab723-inference scrapes /metrics on port http of the inference and inference-gpu services'
}

function Get-KubeRayRelease {
    # The kuberay-operator Helm release's status, such as deployed, failed, or pending-install, or none. helm history
    # returns just the status. helm status would return the whole release, with the chart's large Ray CRDs.
    $history = Invoke-Tool -FilePath $HelmExe -Display 'helm history kuberay-operator' -AllowFailure -RetryOn $KubeTransient -Arguments @(
        'history', 'kuberay-operator', '--max', '1', '--namespace', 'kuberay-system', '--kubeconfig', $Kubeconfig, '--output', 'json')
    $state = ''
    if ($history.ExitCode -eq 0) {
        # ForEach-Object unrolls the array, which ConvertFrom-Json in Windows PowerShell returns as one object.
        try { $state = [string]($history.Out | ConvertFrom-Json | ForEach-Object { $_ } | Select-Object -Last 1).status } catch { }
    }
    if ($state) { return $state }
    return 'none'
}

function Clear-PendingKubeRay {
    # A run that stopped during an install leaves the release pending, which blocks the next one, so remove it.
    $state = Get-KubeRayRelease
    if ($state -like 'pending*') {
        Write-Log "  The kuberay-operator release is $state, so it's removed before the install."
        Invoke-Tool -FilePath $HelmExe -Display 'helm uninstall kuberay-operator' -RetryOn $KubeTransient -Arguments @(
            'uninstall', 'kuberay-operator', '--namespace', 'kuberay-system', '--kubeconfig', $Kubeconfig, '--wait', '--ignore-not-found') |
            Out-Null
    }
}

function Install-KubeRay {
    New-Item -ItemType Directory -Path $env:HELM_CACHE_HOME, $env:HELM_CONFIG_HOME, $env:HELM_DATA_HOME -Force | Out-Null
    $install = @('upgrade', '--install', 'kuberay-operator', 'kuberay-operator', '--repo', 'https://ray-project.github.io/kuberay-helm/',
                 '--version', [string]$Cfg.KubeRayChartVersion, '--namespace', 'kuberay-system', '--create-namespace',
                 '--wait', '--timeout', '10m0s', '--kubeconfig', $Kubeconfig)
    # In one run on a new cluster, the API server refused the chart's ClusterRole after Helm had created the Ray CRDs and
    # the operator's deployment. So try three times, a minute apart, and after a failure log what this run's identity may
    # do with ClusterRoles. The last try uses client-side apply, as Helm 3 did, in case the problem is specific to Helm 4's
    # server-side apply.
    $attempts = 3
    for ($attempt = 1; $true; $attempt++) {
        Clear-PendingKubeRay
        $method = if ($attempt -eq $attempts) { @('--server-side=false') } else { @() }
        try {
            Invoke-Tool -FilePath $HelmExe -Display 'helm upgrade --install kuberay-operator' -Arguments ($install + $method) | Out-Null
            break
        } catch {
            if ($attempt -ge $attempts) { throw }
            $answers = foreach ($verb in 'create', 'escalate', 'bind') {
                "$verb $((Invoke-Kubectl @('auth', 'can-i', $verb, 'clusterroles.rbac.authorization.k8s.io') -AllowFailure).Out.Trim())"
            }
            Write-Log ("  Attempt $attempt of $attempts failed. Can this run's identity change ClusterRoles? $($answers -join ', '). " +
                       'Trying again in 60 seconds.')
            Start-Sleep -Seconds 60
        }
    }
    $how = if ($attempt -gt 1) { ", on attempt $attempt of $attempts" } else { '' }
    return "KubeRay operator $($Cfg.KubeRayChartVersion) in kuberay-system$how"
}

function Set-Workloads {
    $deployed = New-Object System.Collections.Generic.List[string]
    $problems = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $workloads = [ordered]@{
        'notebook'   = @('lab-notebook', $NotebookYaml, 'NOTEBOOK_IMAGE')
        'lab-client' = @('lab-client', $LabClientYaml, 'LAB_CLIENT_IMAGE')
        'loadgen'    = @('loadgen', $LoadgenYaml, 'LOADGEN_IMAGE')
    }
    foreach ($key in @($workloads.Keys)) {
        $name, $template, $placeholder = $workloads[$key]
        if ($Images[$key]) {
            Invoke-Apply $name (Format-Template $template @{ $placeholder = $Images[$key] })
            $deployed.Add($name)
        } else {
            $skipped.Add($name)
        }
    }
    if ($skipped.Count -gt 0) { $problems.Add("Not deployed, because their images are missing: $($skipped -join ', ').") }
    # The Ray cluster comes last, so that a KubeRay problem doesn't keep the other workloads from the lab. A failed
    # install can leave the Ray resource types and the operator's pod without the operator's permissions, so only a
    # deployed release counts.
    $release = Get-KubeRayRelease
    if ($release -ne 'deployed') {
        $problems.Add("RayCluster ray-lab wasn't created, because the KubeRay operator isn't installed (Helm release: $release). " +
                      'Check the KubeRay operator step.')
    } else {
        try {
            # KubeRay doesn't replace running pods when the RayCluster's image changes, so a new image means a new Ray cluster.
            $current = Get-KubeJson @('get', 'raycluster', 'ray-lab', '--namespace', 'ray')
            $currentImage = if ($current) { [string]@($current.spec.headGroupSpec.template.spec.containers)[0].image } else { '' }
            if ($currentImage -and $currentImage -ne $Images['ray']) {
                Write-Log "  ray-lab runs $currentImage, so it's deleted and created again with $($Images['ray'])."
                Invoke-Kubectl @('delete', 'raycluster', 'ray-lab', '--namespace', 'ray', '--ignore-not-found', '--wait=true', '--timeout=5m') |
                    Out-Null
            }
            Invoke-Apply 'ray-cluster' (Format-Template $RayClusterYaml @{
                RAY_VERSION = $Cfg.RayVersion; RAY_IMAGE = $Images['ray']; RAY_WORKERS = $Cfg.RayWorkers })
            $deployed.Add("RayCluster ray-lab ($($Images['ray']))")
        } catch {
            $problems.Add("RayCluster ray-lab wasn't created. $($_.Exception.Message)")
        }
    }
    $done = if ($deployed.Count) { "Deployed $($deployed -join ', ')." } else { 'Deployed nothing.' }
    if ($problems.Count -gt 0) { throw "$done $($problems -join ' ')" }
    return "Deployed $($deployed -join ', ')"
}

function Wait-Workloads {
    $ready = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(@('ai-lab', 'lab-client'), @('ray', 'lab-notebook'))) {
        if (Get-KubeJson @('get', 'deployment', $item[1], '--namespace', $item[0])) {
            Invoke-Kubectl @('rollout', 'status', "deployment/$($item[1])", '--namespace', $item[0], '--timeout=15m') | Out-Null
            $ready.Add($item[1])
        }
    }
    $release = Get-KubeRayRelease
    $operator = Get-KubeJson @('get', 'deployment', 'kuberay-operator', '--namespace', 'kuberay-system')
    $rayCluster = Get-KubeJson @('get', 'raycluster', 'ray-lab', '--namespace', 'ray')
    $why = if ($release -ne 'deployed') { "the KubeRay operator isn't installed (Helm release: $release). Check the KubeRay operator step" }
           elseif (-not $operator -or [int]$operator.status.availableReplicas -lt 1) { "the KubeRay operator isn't running. Check the KubeRay operator step" }
           elseif (-not $rayCluster) { "RayCluster ray-lab doesn't exist. Check the Ray cluster, notebook, lab-client, and loadgen step" }
           else { '' }
    if ($why) {
        $readyText = if ($ready.Count) { "Ready: $($ready -join ', '). " } else { '' }
        throw "${readyText}Not waiting for the Ray cluster, because $why."
    }
    # New nodes for the Ray pods come from node auto-provisioning, so allow time for them.
    $cluster = Wait-Until 'RayCluster ray-lab to be ready' 25 {
        $current = Get-KubeJson @('get', 'raycluster', 'ray-lab', '--namespace', 'ray')
        $isReady = $current -and $current.status.state -eq 'ready' -and
                   [int]$current.status.availableWorkerReplicas -ge [int]$current.status.desiredWorkerReplicas
        if ($isReady) { $current } else { $null }
    } 20
    $ready.Add("ray-lab with $($cluster.status.availableWorkerReplicas) workers")
    return "Ready: $($ready -join ', ')"
}

function Invoke-PrePull {
    # Pulls the lab images onto every current node, so that attendees' pods start quickly. The GPU image
    # can't be pre-pulled, because no GPU node exists yet.
    $list = @('inference', 'lab-client', 'loadgen', 'ray', 'notebook' | ForEach-Object { $Images[$_] } |
              Where-Object { $_ } | Select-Object -Unique)
    if ($list.Count -eq 0) { throw 'No lab images to pre-pull.' }
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $list.Count; $i++) {
        foreach ($line in @("        - name: pull-$i", "          image: $($list[$i])",
                            '          command: ["sh", "-c", "exit 0"]', '          resources:',
                            '            requests: { cpu: 100m, memory: 128Mi }',
                            '            limits: { cpu: 100m, memory: 128Mi }')) { $lines.Add($line) }
    }
    $yaml = @"
apiVersion: v1
kind: Namespace
metadata:
  name: lab723-prepull
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: lab723-prepull
  namespace: lab723-prepull
spec:
  selector:
    matchLabels:
      app: lab723-prepull
  template:
    metadata:
      labels:
        app: lab723-prepull
    spec:
      terminationGracePeriodSeconds: 1
      initContainers:
$($lines -join "`n")
      containers:
        - name: hold
          image: $($list[0])
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { cpu: 100m, memory: 128Mi }
          readinessProbe:
            exec:
              command: ["sh", "-c", "exit 0"]
          livenessProbe:
            exec:
              command: ["sh", "-c", "exit 0"]
"@
    Invoke-Apply 'prepull' $yaml
    try {
        $nodeCount = Wait-Until 'the lab images to be pulled on every node' 20 {
            $daemonSet = Get-KubeJson @('get', 'daemonset', 'lab723-prepull', '--namespace', 'lab723-prepull')
            $desired = [int]$daemonSet.status.desiredNumberScheduled
            if ($desired -gt 0 -and [int]$daemonSet.status.numberReady -eq $desired) { "$desired" } else { $null }
        } 20
    } finally {
        Invoke-Kubectl @('delete', 'namespace', 'lab723-prepull', '--wait=false', '--ignore-not-found') -AllowFailure | Out-Null
    }
    $imageText = if ($list.Count -eq 1) { '1 image' } else { "$($list.Count) images" }
    $nodeText = if ([int]$nodeCount -eq 1) { '1 node' } else { "$nodeCount nodes" }
    return "Pre-pulled $imageText on $nodeText, and then removed the pre-puller"
}

function Start-IdentityCheck {
    Invoke-Kubectl @('delete', 'job', 'lab723-wi-check', '--namespace', 'ai-lab', '--ignore-not-found', '--wait=true') | Out-Null
    Invoke-Apply 'wi-check' (Format-Template $IdentityCheckYaml @{
        SMOKE_TEST_IMAGE = $Cfg.SmokeTestImage; STORAGE_ACCOUNT = $Lab.storageName; MODEL_CONTAINER = $Cfg.ModelContainer })
    return 'Started job lab723-wi-check, which reads the model container as the inference ServiceAccount'
}

function Complete-IdentityCheck {
    $Lab.identityCheck = 'not run'
    $outcome = Wait-Until 'the workload identity check' 15 {
        $job = Get-KubeJson @('get', 'job', 'lab723-wi-check', '--namespace', 'ai-lab')
        if (-not $job) { 'missing' }
        elseif ([int]$job.status.succeeded -ge 1) { 'succeeded' }
        elseif (@($job.status.conditions | Where-Object { $_.type -eq 'Failed' -and $_.status -eq 'True' }).Count -gt 0) { 'failed' }
        else { $null }
    } 20
    $logs = (Invoke-Kubectl @('logs', 'job/lab723-wi-check', '--namespace', 'ai-lab', '--tail=20') -AllowFailure).Out
    Invoke-Kubectl @('delete', 'job', 'lab723-wi-check', '--namespace', 'ai-lab', '--ignore-not-found') -AllowFailure | Out-Null
    $Lab.identityCheck = $outcome
    if ($outcome -ne 'succeeded') {
        throw "The check pod couldn't read the model container with workload identity ($outcome). $(Limit-Text $logs 400)"
    }
    return 'A pod using the inference ServiceAccount signed in with workload identity and read the model container'
}

function Get-CapacityPlan($Nodes) {
    # The millicores to reserve on each lab node, so that the spare CPUs come to $Warm.AimCpu, counted without the current
    # capacity pods. A node that only capacity pods hold keeps 100m, so that NAP doesn't remove it as empty. The rest comes
    # first from the nodes with the least room, down to 200m each, which leaves room for DaemonSet pods, and last from the
    # node with the most room, down to 2.5 CPUs, so that the large profile still fits there.
    $list = @(foreach ($node in @($Nodes | Where-Object { $_ })) {
        [pscustomobject]@{
            Name   = $node.Name
            Held   = $node.Held
            Free   = [int][Math]::Floor(($node.Cpu + $node.CapacityCpu) * 1000 + 0.001)
            Memory = $node.Memory + $node.CapacityMemory
            Plan   = 0
        }
    })
    if ($list.Count -eq 0) { return }
    $step = 50
    $excess = -[int]($Warm.AimCpu * 1000)
    foreach ($node in $list) { $excess += $node.Free }
    $anchor = @(@($list | Where-Object { $_.Memory -ge $Warm.LargeGiB } | Sort-Object -Property Free -Descending) +
                @($list | Sort-Object -Property Free -Descending))[0]
    foreach ($node in $list) {
        if (-not $node.Held) { $node.Plan = 100; $excess -= 100 }
    }
    foreach ($node in @($list | Where-Object { $_ -ne $anchor } | Sort-Object -Property Free)) {
        $take = [Math]::Min($node.Free - 200 - $node.Plan, $excess)
        $take -= $take % $step
        if ($take -ge $step) { $node.Plan += $take; $excess -= $take }
    }
    $take = [Math]::Min($anchor.Free - [int](($Warm.LargeCpu + 0.5) * 1000) - $anchor.Plan, $excess)
    $take -= $take % $step
    if ($take -ge $step) { $anchor.Plan += $take }
    foreach ($node in $list) {
        if ($node.Plan -gt 0) { [pscustomobject]@{ Node = $node.Name; CpuMilli = [int]$node.Plan } }
    }
}

function New-CapacityYaml([string]$Name, [int]$CpuMilli, [string]$Memory, [string]$Node, [string]$Image) {
    $affinity = ''
    if ($Node) {
        $affinity = ((@('      affinity:', '        nodeAffinity:', '          requiredDuringSchedulingIgnoredDuringExecution:',
                        '            nodeSelectorTerms:', '              - matchExpressions:',
                        '                  - key: kubernetes.io/hostname', '                    operator: In',
                        ('                    values: ["{0}"]' -f $Node)) -join "`n") + "`n")
    }
    $role = if ($Node) { 'reserve' } else { 'placeholder' }
    return (Format-Template $CapacityYaml @{ NAME = $Name; ROLE = $role; CPU = "$($CpuMilli)m"; MEMORY = $Memory
                                             IMAGE = $Image; AFFINITY = $affinity })
}

function Set-CapacityPods($Plan, [string]$Image) {
    # Replaces the capacity pods with the plan's reserve. Removing them first leaves room for each new one on its node, and
    # takes seconds, much less than the 30 seconds after which NAP removes an empty node.
    Invoke-Kubectl @('delete', 'deployment', '--namespace', $CapacityNs, '--selector', 'app=lab723-capacity',
                     '--cascade=foreground', '--wait=true', '--timeout=3m', '--ignore-not-found') | Out-Null
    $documents = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Plan | Where-Object { $_ })) {
        $documents.Add((New-CapacityYaml ('reserve-{0}' -f ($documents.Count + 1)) $item.CpuMilli '128Mi' $item.Node $Image))
    }
    if ($documents.Count -eq 0) { return }
    Invoke-Apply 'capacity-reserve' ($documents -join "`n---`n")
    $expected = $documents.Count
    Wait-Until 'the capacity reserve to start' 5 {
        $running = @(Get-KubeItems @('get', 'pods', '--namespace', $CapacityNs, '--selector', 'lab723-capacity/role=reserve') |
                     Where-Object { $_.status.phase -eq 'Running' -and -not $_.metadata.deletionTimestamp })
        if ($running.Count -ge $expected) { $running.Count } else { $null }
    } 10 | Out-Null
}

function Add-WarmNode($Nodes, [string]$Image) {
    # NAP adds a node only for a pod that fits on no node. So the placeholder asks for more CPU than any lab node has free,
    # and for 6 GiB, so that NAP picks a VM size with room for inference pods too. It holds the new node until the
    # capacity reserve replaces it.
    $most = 0.0
    foreach ($node in @($Nodes)) { $most = [Math]::Max($most, [double]$node.Cpu) }
    $cpuMilli = [Math]::Max(2600, [int][Math]::Ceiling(($most + 0.1) * 20) * 50)
    $known = @($Nodes | ForEach-Object { $_.Name })
    Write-Log "  Asking NAP for a node: placeholder warm-node requests $($cpuMilli)m CPU and 6Gi, more than any lab node has free."
    Invoke-Apply 'capacity-placeholder' (New-CapacityYaml 'warm-node' $cpuMilli '6Gi' '' $Image)
    try {
        $pod = Wait-Until 'NAP to add a node for the spare capacity' 12 {
            $running = @(Get-KubeItems @('get', 'pods', '--namespace', $CapacityNs, '--selector', 'lab723-capacity/role=placeholder') |
                         Where-Object { $_.status.phase -eq 'Running' -and $_.spec.nodeName })
            if ($running.Count) { $running[0] } else { $null }
        } 15
    } catch {
        $why = ''
        try {
            $why = (@(Get-KubeItems @('get', 'events', '--namespace', $CapacityNs) | Select-Object -Last 2 |
                      ForEach-Object { "$($_.reason): $($_.message)" }) -join ' ')
        } catch { }
        Invoke-Kubectl @('delete', 'deployment', 'warm-node', '--namespace', $CapacityNs, '--ignore-not-found', '--wait=false') -AllowFailure |
            Out-Null
        throw "NAP didn't add a node within 12 minutes, so the spare capacity is unchanged. $(Limit-Text $why 300)"
    }
    $name = [string]$pod.spec.nodeName
    if ($known -contains $name) { return "The placeholder fit on $name, so no node was needed." }
    $size = ''
    $node = Get-KubeJson @('get', 'node', $name)
    if ($node) { $size = " ($([string]$node.metadata.labels.'node.kubernetes.io/instance-type'))" }
    $pulled = 'and the lab images were pre-pulled on it'
    try { Invoke-PrePull | Out-Null } catch { $pulled = "but the lab images weren't pre-pulled on it. $($_.Exception.Message)" }
    return "NAP added node $name$size, $pulled."
}

function Set-WarmCapacity {
    # Exercises 2 to 4 need the lab nodes' spare capacity in a narrow range ($Warm), and NAP chooses the nodes' VM sizes, so
    # it varies by launch. Too little: the placeholder has NAP add a node. Too much: the capacity reserve, pods that only
    # request CPU, holds the extra. It runs after the pre-pull, which needs a little room on every node.
    if (-not $Cfg.WarmCapacity) { return 'Not changed, because WarmCapacity is $false. The readiness gate still checks it.' }
    $nodes = @(Get-LabCapacity -InUse)
    if ($nodes.Count -eq 0) { throw "No lab node runs the lab's pods." }
    $current = Test-WarmCapacity $nodes
    $placeholders = @(Get-KubeItems @('get', 'deployments', '--namespace', $CapacityNs, '--selector', 'lab723-capacity/role=placeholder'))
    if ($current.Passed -and $placeholders.Count -eq 0) { return "No change needed. $($current.Text)" }
    $image = [string]$Images['lab-client']
    if (-not $image) { throw "The lab-client image is missing, so the capacity pods can't run. $($current.Text)" }
    Write-Log "  Before: $($current.Text)"
    Invoke-Apply 'capacity-namespace' $CapacityNamespaceYaml
    # Decide from the capacity without the capacity pods, so that running this again gets the same result.
    $without = @($nodes | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Size = $_.Size; Cpu = $_.Cpu + $_.CapacityCpu; Memory = $_.Memory + $_.CapacityMemory
                           CapacityCpu = 0.0; CapacityMemory = 0.0; Held = $_.Held } })
    $added = ''
    if (-not (Test-WarmCapacity $without).Enough) {
        $added = Add-WarmNode $nodes $image
        $nodes = @(Get-LabCapacity -InUse)
    }
    $plan = @(Get-CapacityPlan $nodes)
    $planText = if ($plan.Count) { (@($plan | ForEach-Object { '{0} {1}m' -f $_.Node, $_.CpuMilli }) -join ', ') } else { 'none' }
    Write-Log "  Capacity reserve: $planText"
    Set-CapacityPods $plan $image
    $after = Test-WarmCapacity @(Get-LabCapacity -InUse)
    $reserved = 0
    foreach ($item in $plan) { $reserved += $item.CpuMilli }
    $what = if ($plan.Count) { 'Reserved {0:N2} CPUs with {1} pods in {2}.' -f ($reserved / 1000), $plan.Count, $CapacityNs }
            else { 'No capacity reserve needed.' }
    $before = 'Before: {0:N1} spare CPUs.' -f $current.Total
    $text = (@($added, $what, $before, "Now: $($after.Text)") | Where-Object { $_ }) -join ' '
    if (-not $after.Passed) { throw $text }
    return $text
}

function Get-MissingLabFiles([string]$Root) {
    # The files in $LabStepFiles that aren't in $Root, and the folders in $LabStepFolders that have no YAML file.
    $missing = @($LabStepFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf) })
    $missing += @($LabStepFolders | Where-Object {
        @(Get-ChildItem -LiteralPath (Join-Path $Root $_) -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -in '.yaml', '.yml' }).Count -eq 0 } | ForEach-Object { "$_\" })
    return $missing
}

function Get-UnrenderedLabFiles([string]$Root) {
    # The YAML files in $Root, relative to it, that still have a placeholder.
    $pattern = ($Placeholders | ForEach-Object { [regex]::Escape($_) }) -join '|'
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -in '.yaml', '.yml' } | Select-String -Pattern $pattern -List |
             ForEach-Object { $_.Path.Substring($Root.TrimEnd('\').Length).TrimStart('\') })
}

function Update-LabFiles {
    # Puts clean copies of the lab files in LabRoot, where the lab steps open, apply, and patch them: from LabFilesZipUrl,
    # if it's set, or else from the content repository. It mirrors each of their top-level folders, so a file that isn't
    # in the lab content can't change what "kubectl apply -f 02-deploy/" applies, and it keeps other items in LabRoot.
    # Then it renders the lab's names into the YAML files, and checks that every file that the lab steps use is there.
    $root = ([string]$Cfg.LabRoot).TrimEnd('\')
    $staging = Join-Path $LcaDir 'labfiles'
    $from = ''
    $removed = 0
    try {
        $sourceDir = ''
        if ($Cfg.LabFilesZipUrl) {
            $zip = Join-Path $LcaDir 'labfiles.zip'
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $Cfg.LabFilesZipUrl -OutFile $zip -UseBasicParsing
            Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            $top = @(Get-ChildItem -LiteralPath $staging)
            $sourceDir = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $staging }
            $from = [string]$Cfg.LabFilesZipUrl
        } elseif ($ContentDir) {
            $sourceDir = Join-Path $ContentDir 'labfiles'
            $from = [string]$Lab.content
        }
        if ($sourceDir) {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            foreach ($folder in @(Get-ChildItem -LiteralPath $sourceDir -Directory)) {
                $target = Join-Path $root $folder.Name
                if (-not (Test-Path -LiteralPath $target)) { continue }
                $wanted = @{}
                foreach ($file in @(Get-ChildItem -LiteralPath $folder.FullName -Recurse -File -Force)) {
                    $wanted[$file.FullName.Substring($folder.FullName.Length)] = $true
                }
                foreach ($file in @(Get-ChildItem -LiteralPath $target -Recurse -File -Force)) {
                    if (-not $wanted.ContainsKey($file.FullName.Substring($target.Length))) {
                        Remove-Item -LiteralPath $file.FullName -Force
                        $removed++
                    }
                }
            }
            Copy-Item -Path (Join-Path $sourceDir '*') -Destination $root -Recurse -Force
        }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.yaml', '.yml' })
    if ($files.Count -eq 0) { throw "$root has no YAML files. Check the Lab content step, or add the lab files to the image." }
    # A name that the resource template didn't return stays a placeholder, which this step and the readiness gate report.
    $values = [ordered]@{
        '<registry>' = [string]$Lab.registryLoginServer; '<storage-account>' = [string]$Lab.storageName
        '<model-container>' = [string]$Cfg.ModelContainer; '<workload-identity-client-id>' = [string]$Lab.identityClientId
    }
    $changed = 0
    foreach ($file in $files) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $updated = $text
        foreach ($key in $values.Keys) { if ($values[$key]) { $updated = $updated.Replace($key, $values[$key]) } }
        if ($updated -cne $text) {
            [IO.File]::WriteAllText($file.FullName, $updated, $Utf8)
            $changed++
        }
    }
    $copied = if ($from) { "Copied the lab files from $from to $root" } else { "Kept the lab files in $root, because there's no lab content to copy" }
    if ($removed -eq 1) { $copied += ', and removed 1 file that isn''t part of them' }
    elseif ($removed -gt 1) { $copied += ", and removed $removed files that aren't part of them" }
    $missing = @(Get-MissingLabFiles $root)
    $unrendered = @(Get-UnrenderedLabFiles $root)
    if ($missing.Count -gt 0 -or $unrendered.Count -gt 0) {
        $missingText = if ($missing.Count) { $missing -join ', ' } else { 'none' }
        $unrenderedText = if ($unrendered.Count) { $unrendered -join ', ' } else { 'none' }
        throw "$copied. Files that the lab steps use and that are missing: $missingText. Files with placeholders: $unrenderedText."
    }
    return "$copied. Rendered the lab's names into $changed of $($files.Count) YAML files. Every file that the lab steps use is there."
}

# ---------------------------------------------------------------------------------------------
# Readiness gate: section 11 of the prerequisites, plus the launch state from sections 4 to 9.
# FAIL marks a lab that isn't ready. WARN marks something to review that doesn't break the lab.
# ---------------------------------------------------------------------------------------------
function Test-Readiness {
    $Checks.Clear()
    function Add-Check([string]$Name, [bool]$Passed, [string]$Detail, [string]$Severity) {
        $Checks.Add([pscustomobject]@{ check = $Name; result = $(if ($Passed) { 'PASS' } else { $Severity }); detail = $Detail })
    }
    function Invoke-Check([string]$Name, [string]$Severity, [scriptblock]$Test) {
        # A check returns @(passed, detail), or @(passed, detail, severity) to change the severity of a failure.
        try {
            $outcome = @(& $Test)
            $level = if ($outcome.Count -ge 3 -and $outcome[2]) { [string]$outcome[2] } else { $Severity }
            Add-Check $Name ([bool]$outcome[0]) ([string]$outcome[1]) $level
        } catch {
            Add-Check $Name $false "The check failed: $($_.Exception.Message)" $Severity
        }
    }
    function Join-Names($Names) {
        $list = @($Names | Where-Object { $_ })
        if ($list.Count -eq 0) { return 'none' }
        return ($list -join ', ')
    }

    Invoke-Check 'LCA Azure sign-in' 'FAIL' {
        # The service principal in the LCA's own profile, or, in a manual run, you in your own profile.
        $account = Get-AzJson @('account', 'show') -AllowFailure
        $type = if ($Manual) { 'user' } else { 'servicePrincipal' }
        $name = if ($Manual) { [string]$Cfg.PortalUser } else { [string]$Cfg.ClientId }
        $passed = $account -and $account.id -eq $Cfg.SubscriptionId -and $account.user.type -eq $type -and $account.user.name -eq $name
        $where = if ($Manual) { 'Your Azure CLI sign-in (manual run)' } else { "The LCA's own Azure CLI profile" }
        @($passed, ("${where}: subscription $($account.name) ($($account.id)), signed in as " +
                    "$($account.user.type) $($account.user.name)"))
    }
    Invoke-Check 'Attendee Azure CLI' 'FAIL' {
        # The attendee signs in with their own lab account. The service principal must never be in their profile.
        $entries = @(Get-ChildItem -LiteralPath $LabAzureDir -Filter 'service_principal_entries*' -File -Force -ErrorAction SilentlyContinue)
        $profileFile = Join-Path $LabAzureDir 'azureProfile.json'
        $inProfile = [bool]$Cfg.ClientId -and (Test-Path -LiteralPath $profileFile) -and
                     [bool](Select-String -LiteralPath $profileFile -SimpleMatch ([string]$Cfg.ClientId) -Quiet)
        if ($entries.Count -gt 0 -or $inProfile) {
            return @($false, ("The lab user's Azure CLI profile has a service principal sign-in, which the attendee mustn't get. " +
                              'Run az account clear as the lab user, or run the prepare LCA again.'))
        }
        $configFile = Join-Path $LabAzureDir 'config'
        $browser = (Test-Path -LiteralPath $configFile) -and
                   [bool](Select-String -LiteralPath $configFile -Pattern '^\s*enable_broker_on_windows\s*=\s*(false|no|off|0)\s*$' -Quiet)
        @($browser, "No service principal sign-in in the lab user's profile. Browser sign-in, which reuses the portal sign-in: $browser",
          $(if (-not $browser) { 'WARN' }))
    }
    Invoke-Check 'kubeconfig' 'FAIL' {
        $contexts = @((Invoke-Kubectl @('config', 'get-contexts', '--output', 'name') -AllowFailure).Out -split "`n" |
                      Where-Object { $_.Trim() })
        $usesKubelogin = (Test-Path -LiteralPath $Kubeconfig) -and (Select-String -LiteralPath $Kubeconfig -Pattern 'kubelogin' -Quiet)
        @(($contexts.Count -eq 1 -and $usesKubelogin), "Contexts: $($contexts -join ', '). kubelogin exec plugin: $usesKubelogin")
    }
    Invoke-Check 'Nodes' 'FAIL' {
        $nodes = @(Get-KubeItems @('get', 'nodes'))
        $gpu = @($nodes | Where-Object { Test-GpuNode $_ })
        $readyCpu = @($nodes | Where-Object { -not (Test-GpuNode $_) -and (Test-NodeReady $_) })
        @(($readyCpu.Count -ge 1 -and $gpu.Count -eq 0), "Ready CPU nodes: $($readyCpu.Count). GPU nodes: $($gpu.Count)")
    }
    Invoke-Check 'Node pools' 'FAIL' {
        $pools = @(Get-KubeItems @('get', 'nodepools.karpenter.sh'))
        $names = @($pools | ForEach-Object { $_.metadata.name })
        $problems = New-Object System.Collections.Generic.List[string]
        foreach ($required in 'default', 'gpu') { if ($names -notcontains $required) { $problems.Add("$required is missing") } }
        $default = $pools | Where-Object { $_.metadata.name -eq 'default' } | Select-Object -First 1
        if ($default -and $Cfg.PatchDefaultNodePool -and $default.spec.disruption.consolidationPolicy -ne 'WhenEmpty') {
            $problems.Add("default consolidates with $($default.spec.disruption.consolidationPolicy), not WhenEmpty")
        }
        $sizes = if ($default) { @(Get-PoolSizes $default) } else { @() }
        if ($default -and $CpuVmSizes.Count -gt 0) {
            $other = @($sizes | Where-Object { $CpuVmSizes -notcontains $_ })
            if ($sizes.Count -eq 0 -or $other.Count -gt 0) {
                $allowed = if ($sizes.Count) { $sizes -join ', ' } else { 'any size of its families' }
                $problems.Add("default allows $allowed, not only $($CpuVmSizes -join ', '), so NAP can pick a size that the access control policy denies")
            }
        }
        $detail = "NodePools: $(Join-Names $names)"
        if ($sizes.Count -gt 0) { $detail += ". default sizes: $($sizes -join ', ')" }
        if ($problems.Count -gt 0) { $detail += '. ' + ($problems -join '; ') }
        @(($problems.Count -eq 0), $detail)
    }
    Invoke-Check 'GPU node pool' 'FAIL' {
        $problems = New-Object System.Collections.Generic.List[string]
        $pool = Get-KubeJson @('get', 'nodepools.karpenter.sh', 'gpu')
        if (-not $pool) {
            $problems.Add('NodePool gpu is missing')
        } else {
            $requirements = @($pool.spec.template.spec.requirements)
            $sizes = @($requirements | Where-Object { $_.key -eq 'karpenter.azure.com/sku-name' } | ForEach-Object { $_.values })
            $capacity = @($requirements | Where-Object { $_.key -eq 'karpenter.sh/capacity-type' } | ForEach-Object { $_.values })
            $taints = @($pool.spec.template.spec.taints | Where-Object { $_.key -eq 'nvidia.com/gpu' -and $_.effect -eq 'NoSchedule' })
            if (($sizes -join ',') -ne $Cfg.GpuVmSize) { $problems.Add("sizes are '$($sizes -join ',')', not $($Cfg.GpuVmSize) only") }
            if (($capacity -join ',') -ne 'on-demand') { $problems.Add("capacity types are '$($capacity -join ',')', not on-demand only") }
            if ($taints.Count -eq 0) { $problems.Add('no nvidia.com/gpu NoSchedule taint') }
            if ([string]$pool.spec.limits.cpu -ne [string]$Cfg.GpuCpuLimit) {
                $problems.Add("cpu limit is '$($pool.spec.limits.cpu)', not $($Cfg.GpuCpuLimit)")
            }
            if ($pool.spec.disruption.consolidationPolicy -ne 'WhenEmpty') { $problems.Add("consolidation isn't WhenEmpty") }
            $notReady = Get-NotReady 'NodePool gpu' $pool
            if ($notReady) { $problems.Add($notReady) }
        }
        $class = Get-KubeJson @('get', 'aksnodeclasses.karpenter.azure.com', 'gpu')
        if (-not $class) { $problems.Add('AKSNodeClass gpu is missing') }
        elseif ([string]$class.spec.tags.EnableManagedGPUExperience -ne 'true') { $problems.Add('AKSNodeClass gpu lacks the managed GPU tag') }
        else {
            $notReady = Get-NotReady 'AKSNodeClass gpu' $class
            if ($notReady) { $problems.Add($notReady) }
        }
        $feature = Get-GpuFeatureState
        $Lab.gpuFeatureState = $feature
        if ($feature -and $feature -notin 'Registered', 'NotFound', 'Unknown') { $problems.Add("ManagedGPUExperiencePreview is $feature") }
        if ($problems.Count -gt 0) { return @($false, ($problems -join '; ')) }
        if ($feature -ne 'Registered') {
            $state = if ($feature) { $feature } else { 'unknown' }
            return @($false, "The pool is configured, but the ManagedGPUExperiencePreview state is $state.", 'WARN')
        }
        @($true, "$($Cfg.GpuVmSize) only, on-demand, cpu limit $($Cfg.GpuCpuLimit), WhenEmpty, managed GPU, feature registered")
    }
    # Whether NAP can create the GPU node at all: the size isn't restricted for this subscription, and the quota has room.
    Invoke-Check 'GPU capacity' 'FAIL' { Test-GpuAccess }
    Invoke-Check 'NodeClaims' 'FAIL' {
        $claims = @(Get-KubeItems @('get', 'nodeclaims.karpenter.sh'))
        $stuck = @($claims | Where-Object { -not (Test-NodeReady $_) } | ForEach-Object { $_.metadata.name })
        @(($stuck.Count -eq 0), "NodeClaims: $($claims.Count). Not ready: $(Join-Names $stuck)")
    }
    Invoke-Check 'Lab namespace' 'FAIL' {
        $deployments = @(Get-KubeItems @('get', 'deployments', '--namespace', 'ai-lab'))
        $client = $deployments | Where-Object { $_.metadata.name -eq 'lab-client' } | Select-Object -First 1
        $load = $deployments | Where-Object { $_.metadata.name -eq 'loadgen' } | Select-Object -First 1
        $others = @($deployments | Where-Object { $_.metadata.name -notin 'lab-client', 'loadgen' } | ForEach-Object { $_.metadata.name })
        $services = @(Get-KubeItems @('get', 'services', '--namespace', 'ai-lab') | ForEach-Object { $_.metadata.name })
        $ingresses = @(Get-KubeItems @('get', 'ingresses', '--namespace', 'ai-lab') | ForEach-Object { $_.metadata.name })
        $passed = $client -and [int]$client.status.readyReplicas -eq 1 -and $load -and [int]$load.spec.replicas -eq 0 -and
                  $others.Count -eq 0 -and $services.Count -eq 0 -and $ingresses.Count -eq 0
        $loadReplicas = if ($load) { [int]$load.spec.replicas } else { 'missing' }
        @($passed, ("lab-client ready: $([int]$client.status.readyReplicas)/1. loadgen replicas: $loadReplicas. " +
                    "Other deployments: $(Join-Names $others). Services: $(Join-Names $services). Ingresses: $(Join-Names $ingresses)"))
    }
    Invoke-Check 'No autoscaler' 'FAIL' {
        $hpas = @(Get-KubeItems @('get', 'hpa', '--namespace', 'ai-lab'))
        @(($hpas.Count -eq 0), "HorizontalPodAutoscalers in ai-lab: $($hpas.Count)")
    }
    Invoke-Check 'Ray' 'FAIL' {
        $ray = Get-KubeJson @('get', 'raycluster', 'ray-lab', '--namespace', 'ray')
        $passed = $ray -and $ray.status.state -eq 'ready' -and
                  [int]$ray.status.availableWorkerReplicas -eq [int]$ray.status.desiredWorkerReplicas
        $state = if ($ray) { $ray.status.state } else { 'missing' }
        @($passed, "State: $state. Workers available: $([int]$ray.status.availableWorkerReplicas) of $([int]$ray.status.desiredWorkerReplicas)")
    }
    Invoke-Check 'Notebook' 'FAIL' {
        $pods = @(Get-KubeItems @('get', 'pods', '--namespace', 'ray'))
        $notReady = @($pods | Where-Object {
            $_.status.phase -ne 'Running' -or @($_.status.containerStatuses | Where-Object { -not $_.ready }).Count -gt 0 })
        $notebook = @($pods | Where-Object { $_.metadata.labels.app -eq 'lab-notebook' })
        # Exercise 5 opens both notebooks from the root folder of the notebook server, so ask the server what's there.
        $listed = @()
        $listError = ''
        if ($notebook.Count -ge 1) {
            $listing = Invoke-Kubectl @('exec', '--namespace', 'ray', 'deploy/lab-notebook', '--', 'python', '-c', $NotebookListCode) -AllowFailure
            $listed = @($listing.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($listing.ExitCode -ne 0) { $listError = " Couldn't list the notebook server's folder: $(Limit-Text $listing.Err 150)" }
        }
        $missingNotebooks = @($LabNotebooks | Where-Object { $listed -notcontains $_ })
        @(($pods.Count -gt 0 -and $notReady.Count -eq 0 -and $notebook.Count -ge 1 -and $missingNotebooks.Count -eq 0),
          ("Pods in ray: $($pods.Count). Not ready: $($notReady.Count). Notebook pods: $($notebook.Count). " +
           "Notebooks missing from the notebook server's root folder: $(Join-Names $missingNotebooks).$listError"))
    }
    Invoke-Check 'Unhealthy pods' 'FAIL' {
        $rows = @((Invoke-Kubectl @('get', 'pods', '--all-namespaces', '--no-headers', '--output',
            'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,WAIT:.status.containerStatuses[*].state.waiting.reason')).Out -split "`n" |
            Where-Object { $_.Trim() -and $_ -notmatch '^lab723-prepull\s' })
        $bad = @($rows | Where-Object {
            $fields = $_.Trim() -split '\s+'
            $fields[2] -notin 'Running', 'Succeeded' -or $fields[3] -match 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError' })
        $detail = if ($bad) { 'Unhealthy: ' + (($bad | Select-Object -First 5 | ForEach-Object { $_.Trim() -replace '\s+', ' ' }) -join '; ') } else { 'None' }
        @(($bad.Count -eq 0), $detail)
    }
    Invoke-Check 'Permissions' 'FAIL' {
        $denied = New-Object System.Collections.Generic.List[string]
        foreach ($test in @(@('patch', 'deployments', 'ai-lab'), @('create', 'pods/exec', 'ai-lab'),
                            @('create', 'horizontalpodautoscalers', 'ai-lab'), @('create', 'pods/portforward', 'ray'))) {
            $answer = (Invoke-Kubectl @('auth', 'can-i', $test[0], $test[1], '--namespace', $test[2]) -AllowFailure).Out.Trim()
            if ($answer -ne 'yes') { $denied.Add("$($test[0]) $($test[1]) in $($test[2])") }
        }
        $detail = if ($denied.Count) { 'Denied: ' + ($denied -join '; ') } else { 'All four are allowed' }
        @(($denied.Count -eq 0), $detail)
    }
    Invoke-Check 'Benchmark tool' 'FAIL' {
        $result = Invoke-Kubectl @('exec', '--namespace', 'ai-lab', 'deploy/lab-client', '--', 'bench', '--help') -AllowFailure
        $detail = if ($result.ExitCode -eq 0) { 'bench --help works in lab-client' } else { Limit-Text "$($result.Err) $($result.Out)" 200 }
        @(($result.ExitCode -eq 0), $detail)
    }
    Invoke-Check 'Ingress controller' 'FAIL' {
        $services = @(Get-KubeItems @('get', 'services', '--namespace', 'app-routing-system') |
                      Where-Object { $_.spec.type -eq 'LoadBalancer' -and $_.status.loadBalancer.ingress })
        $addresses = @($services | ForEach-Object { $_.status.loadBalancer.ingress | ForEach-Object { $_.ip } })
        $detail = if ($services) { "$($services[0].metadata.name): $($addresses -join ', ')" } else { 'No load balancer with an external IP in app-routing-system' }
        @(($services.Count -gt 0), $detail)
    }
    Invoke-Check 'Lab files' 'FAIL' {
        $root = ([string]$Cfg.LabRoot).TrimEnd('\')
        $missing = @(Get-MissingLabFiles $root)
        $file = Join-Path $root '02-deploy\inference-deployment.yaml'
        $latest = if (Test-Path -LiteralPath $file) { @(Select-String -LiteralPath $file -Pattern ':latest').Count } else { 0 }
        $unrendered = @(Get-UnrenderedLabFiles $root)
        @(($missing.Count -eq 0 -and $latest -eq 1 -and $unrendered.Count -eq 0),
          ("Files that the lab steps use and that are missing from ${root}: $(Join-Names $missing). Lines with :latest in " +
           "02-deploy\inference-deployment.yaml: $latest. Files with placeholders: $(Join-Names $unrendered)"))
    }
    Invoke-Check 'Free ports' 'FAIL' {
        $listening = @(Get-NetTCPConnection -LocalPort 8888, 8265 -State Listen -ErrorAction SilentlyContinue)
        $detail = if ($listening) { 'In use: ' + (($listening | ForEach-Object { $_.LocalPort }) -join ', ') } else { '8888 and 8265 are free' }
        @(($listening.Count -eq 0), $detail)
    }
    Invoke-Check 'Vertical Pod Autoscaler' 'FAIL' {
        $vpas = @(Get-KubeItems @('get', 'verticalpodautoscalers.autoscaling.k8s.io', '--namespace', 'ai-lab') -MissingTypeIsEmpty |
                  Where-Object { $_.spec.updatePolicy.updateMode -notin 'Off', 'Initial' })
        @(($vpas.Count -eq 0), "VPA objects in ai-lab that update running pods: $($vpas.Count)")
    }
    Invoke-Check 'Deployment safeguards' 'FAIL' {
        # The cluster's deploymentSafeguards/default extension resource, which "az aks safeguards show" reads too.
        if (-not $Lab.clusterId) { return @($false, 'The cluster ID is unknown.') }
        $guard = Get-AzJson @('rest', '--method', 'get', '--url',
                              "$($Lab.clusterId)/providers/Microsoft.ContainerService/deploymentSafeguards/default?api-version=2025-07-01") -AllowFailure
        if (-not $guard -or -not $guard.properties) {
            return @($false, ("Couldn't read the cluster's deploymentSafeguards resource. AKS Automatic enforces safeguards by default. " +
                              "Check them with: az aks safeguards show --resource-group $RG --name $($Lab.clusterName)"), 'WARN')
        }
        $excluded = @($guard.properties.excludedNamespaces | Where-Object { $_ })
        @(($guard.properties.level -eq 'Enforce' -and $excluded -notcontains 'ai-lab'),
          ("Level: $($guard.properties.level). Pod Security Standards: $($guard.properties.podSecurityStandardsLevel). " +
           "Excluded namespaces: $(Join-Names $excluded)"))
    }
    Invoke-Check 'Lab images' 'FAIL' {
        if (-not $Lab.registryName) { return @($false, 'The registry is unknown.') }
        $missing = @('inference', 'inference-gpu', 'lab-client', 'loadgen', 'ray', 'notebook' | Where-Object {
            (Invoke-Az @('acr', 'repository', 'show', '--name', $Lab.registryName, '--image', "lab723/$($_):$($Cfg.ImageTag)") -AllowFailure).ExitCode -ne 0
        })
        $detail = if ($missing.Count) { "Missing from $($Lab.registryLoginServer) with tag $($Cfg.ImageTag): $($missing -join ', ')" }
                  else { "All six lab images are in $($Lab.registryLoginServer) with tag $($Cfg.ImageTag)" }
        @(($missing.Count -eq 0), $detail)
    }
    Invoke-Check 'Model files' 'FAIL' {
        $count = Get-BlobCount
        $detail = if ($count -ge 0) { "Files in $($Lab.storageName)/$($Cfg.ModelContainer): $count" } else { "Couldn't list $($Lab.storageName)/$($Cfg.ModelContainer)" }
        @(($count -gt 0), $detail)
    }
    Invoke-Check 'Workload identity' 'FAIL' {
        $result = if ($Lab.identityCheck) { $Lab.identityCheck } else { 'not run' }
        @(($Lab.identityCheck -eq 'succeeded'), "Check pod result at build time: $result")
    }
    Invoke-Check 'Monitoring objects' 'FAIL' {
        $problems = New-Object System.Collections.Generic.List[string]
        if (-not $Lab.prometheusEnabled) { $problems.Add('Managed Prometheus is off') }
        if (-not (Get-KubeJson @('get', 'servicemonitors.azmonitoring.coreos.com', 'lab723-inference', '--namespace', 'ai-lab'))) {
            $problems.Add('ServiceMonitor lab723-inference is missing')
        }
        $secret = Get-KubeJson @('get', 'secret', 'appinsights', '--namespace', 'ai-lab')
        if (-not $secret -or -not $secret.data.APPLICATIONINSIGHTS_CONNECTION_STRING) { $problems.Add('Secret appinsights is missing or empty') }
        $detail = if ($problems.Count) { $problems -join '; ' } else { 'Managed Prometheus, ServiceMonitor lab723-inference, and Secret appinsights' }
        @(($problems.Count -eq 0), $detail)
    }
    Invoke-Check 'Portal user access' 'FAIL' {
        $userId = [string]$Lab.portalUserObjectId
        if (-not $userId) { return @($false, "The portal user's object ID is unknown, so its roles weren't assigned.") }
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($pair in @(@('Azure Kubernetes Service RBAC Cluster Admin', $Lab.clusterId), @('Monitoring Data Reader', $Lab.monitorWorkspaceId),
                            @('Log Analytics Reader', $Lab.logAnalyticsId))) {
            if (-not (Test-RoleAssignment $userId $pair[0] $pair[1])) { $missing.Add($pair[0]) }
        }
        $detail = if ($missing.Count) { 'Missing: ' + ($missing -join ', ') } else { 'AKS RBAC Cluster Admin, Monitoring Data Reader, and Log Analytics Reader' }
        @(($missing.Count -eq 0), $detail)
    }
    Invoke-Check 'kubectl version skew' 'FAIL' {
        $versions = (Invoke-Kubectl @('version', '--output', 'json') -AllowFailure).Out | ConvertFrom-Json
        $client = [int]($versions.clientVersion.minor -replace '\D', '')
        $server = [int]($versions.serverVersion.minor -replace '\D', '')
        @(([Math]::Abs($client - $server) -le 1), "kubectl 1.$client, cluster 1.$server")
    }
    # Metrics arrive a few minutes after the cluster is created, so only the readiness gate LCA fails on them.
    Invoke-Check 'Metrics' $(if ($Mode -eq 'Verify') { 'FAIL' } else { 'WARN' }) {
        if (-not $Lab.prometheusEndpoint) { return @($false, "The Azure Monitor workspace's query endpoint is unknown") }
        $token = Get-AzText @('account', 'get-access-token', '--resource', 'https://prometheus.monitor.azure.com', '--query', 'accessToken')
        $response = Invoke-RestMethod -Uri "$($Lab.prometheusEndpoint)/api/v1/query?query=up" -UseBasicParsing `
                                      -Headers @{ Authorization = "Bearer $token" }
        $up = @($response.data.result | Where-Object { $_.value[1] -eq '1' })
        @(($up.Count -gt 0), "Prometheus targets up: $($up.Count). The inference jobs appear after attendees deploy inference.")
    }
    Invoke-Check 'Monitoring history' 'WARN' {
        # Compare instants. PowerShell 7 reads creationTimestamp as a UTC DateTime, and Windows PowerShell as a string.
        $oldest = @(Get-KubeItems @('get', 'nodes') | ForEach-Object { [DateTimeOffset]$_.metadata.creationTimestamp } | Sort-Object) |
                  Select-Object -First 1
        if (-not $oldest) { return @($false, 'No nodes.') }
        $minutes = [int]([DateTimeOffset]::UtcNow - $oldest).TotalMinutes
        @(($minutes -ge 15), "The oldest node is $minutes minutes old. Dashboards need about 15 minutes of history.")
    }
    Invoke-Check 'Warm capacity' 'WARN' {
        # See $Warm. The prepare LCA's Warm capacity step sets it up, with a capacity reserve or one more node.
        $result = Test-WarmCapacity @(Get-LabCapacity -InUse)
        @($result.Passed, $result.Text)
    }
    Invoke-Check 'Dashboard' 'WARN' {
        $name = [string]$Cfg.DashboardName
        if (-not $name) { return @($true, 'DashboardName is empty, so the lab has no dashboard.') }
        $base = "/subscriptions/$($Cfg.SubscriptionId)/resourceGroups/$RG/providers/Microsoft.Dashboard/dashboards/$name"
        $definition = Get-AzJson @('rest', '--method', 'get', '--url', "$base/dashboardDefinitions/default?api-version=$($Cfg.DashboardApiVersion)") -AllowFailure
        if (-not $definition) { return @($false, "Dashboard $name isn't in $RG. The lab steps open it from the portal's search box, by that name.") }
        $data = [string]$definition.properties.serializedData
        $parsed = if ($data) { $data | ConvertFrom-Json } else { $null }
        $panels = @($parsed.panels | Where-Object { $_ }).Count
        # The cluster's Saved dashboards tab, on its Dashboards with Grafana page, lists only dashboards with this tag.
        $resource = Get-AzJson @('rest', '--method', 'get', '--url', "${base}?api-version=$($Cfg.DashboardApiVersion)") -AllowFailure
        $type = [string]$resource.tags.GrafanaDashboardResourceType
        if ($type -cne $AksDashboardType) {
            $found = if ($type) { "'$type'" } else { 'missing' }
            return @($false, "Dashboard $name in $RG has $panels panels, but its GrafanaDashboardResourceType tag is $found, not '$AksDashboardType', so the cluster's Saved dashboards tab doesn't list it. The lab steps open it from the portal's search box, which still finds it.")
        }
        @(($panels -gt 0), "Dashboard $name ($($parsed.title)) in ${RG}, with $panels panels and the GrafanaDashboardResourceType tag $AksDashboardType")
    }

    $table = ($Checks | Format-Table -AutoSize -Wrap | Out-String -Width 240).TrimEnd()
    Write-Log "Readiness gate:`r`n$table"
    return @($Checks | Where-Object { $_.result -eq 'FAIL' }).Count
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
$mutex = $null
$owned = $false
$RunResult = $null   # The result and message for the summary at the end of the logs
try {
    try {
        $mutex = New-LabMutex
    } catch {
        # Without the lock, two prepare workers could overlap, so prepare stops. The readiness gate only reads.
        if ($Mode -eq 'Prepare') { throw "Couldn't open the LAB723 worker lock. $($_.Exception.Message)" }
        Write-Log "Couldn't open the worker lock, so the readiness gate runs without it. $($_.Exception.Message)"
        $owned = $true
    }
    if ($mutex) {
        $waitMinutes = if ($Mode -eq 'Verify') { 15 } else { 1 }
        try { $owned = $mutex.WaitOne([TimeSpan]::FromMinutes($waitMinutes)) } catch [Threading.AbandonedMutexException] { $owned = $true }
    }
    if (-not $owned) {
        if ($Mode -eq 'Prepare') { Write-Log 'Another LAB723 worker is already running, so this one exits.'; return }
        throw 'The LAB723 prepare worker is still running. Run the readiness gate again when it finishes.'
    }
    Write-Log "LAB723 LCA worker. Mode: $Mode. Run: $RunId."
    Save-State 'Running' 'Starting'

    if ($Mode -eq 'Verify') {
        $prepared = Join-Path $LcaDir 'state-prepare.json'
        if (-not (Test-Path -LiteralPath $prepared)) { throw 'The prepare life cycle action has not run in this VM.' }
        $previous = Get-Content -LiteralPath $prepared -Raw | ConvertFrom-Json
        foreach ($property in $previous.lab.PSObject.Properties) { $Lab[$property.Name] = $property.Value }
        Use-TemplateNames
        Invoke-Step 'Context' { Initialize-Context }
    } else {
        Invoke-Step 'Context' { Initialize-Context }
        Invoke-Step 'Azure sign-in' { Connect-Azure }
        Invoke-Step 'Resource group' { Initialize-ResourceGroup }
        if ($Manual) { Invoke-Step 'Your access to the resource group' { Test-ManualAccess } }
        Invoke-Step 'Resource providers and the GPU preview feature' { Register-Providers } -Optional:(-not $Manual)
        Invoke-Step 'Portal user' { Resolve-PortalUser } -Optional
        Invoke-Step 'Lab content' { Get-LabContent } -Optional
        Invoke-Step 'Azure resources (resource template)' { Set-AzureResources }
        # As soon as the lab's names are known, so the lab steps' files are in place even if a later step fails or waits.
        Invoke-Step 'Lab files' { Update-LabFiles } -Optional
        Invoke-Step 'Role assignments' { Set-RoleAssignments }
        Invoke-Step 'Lab images' { Set-Images } -Optional
        Invoke-Step 'Model files' { Publish-Model } -Optional
        Invoke-Step 'kubeconfig and cluster access' { Set-Kubeconfig }
        Invoke-Step 'Attendee Azure CLI' { Set-AttendeeCli } -Optional
        Invoke-Step 'VS Code shortcuts' { Set-CodeShortcuts } -Optional
        Invoke-Step 'Namespaces, ServiceAccount, and lab settings' { Set-ClusterBase }
        Invoke-Step 'gpu NodePool' { Set-NodePools } -Optional
        Invoke-Step 'ServiceMonitor' { Set-ServiceMonitor } -Optional
        Invoke-Step 'Start the workload identity check' { Start-IdentityCheck } -Optional
        # Optional, so that a KubeRay problem doesn't stop the rest of the lab. The readiness gate's Ray check fails instead.
        Invoke-Step 'KubeRay operator' { Install-KubeRay } -Optional
        Invoke-Step 'Ray cluster, notebook, lab-client, and loadgen' { Set-Workloads } -Optional
        Invoke-Step 'Workloads ready' { Wait-Workloads } -Optional
        Invoke-Step 'Image pre-pull' { Invoke-PrePull } -Optional
        Invoke-Step 'Workload identity check' { Complete-IdentityCheck } -Optional
        # After the pre-pull, which needs a little room on every node, and which runs again for a node that this step adds.
        Invoke-Step 'Warm capacity' { Set-WarmCapacity } -Optional
        Invoke-Step 'GPU preview feature' { Complete-GpuFeature } -Optional
    }

    Write-Log '==> Readiness gate'
    $failures = Test-Readiness
    $stepWarnings = @($Steps | Where-Object { $_.result -eq 'WARN' } | ForEach-Object { $_.step })
    if (Test-CredentialRemoval $failures $stepWarnings.Count) { $failures += Remove-CloudCredential }
    $gateWarnings = @($Checks | Where-Object { $_.result -eq 'WARN' }).Count
    $failedChecks = ($Checks | Where-Object { $_.result -eq 'FAIL' } | ForEach-Object { $_.check }) -join ', '
    $summary = if ($failures -gt 0) { "Readiness gate: $failures failed ($failedChecks), $gateWarnings warnings." }
               else { "Readiness gate passed with $gateWarnings warnings." }
    if ($stepWarnings.Count -gt 0) { $summary += " Steps with warnings: $($stepWarnings -join ', ')." }
    $summary += " Cluster: $($Lab.clusterName). Log: $LogPath"
    $status = Get-RunStatus $failures $stepWarnings.Count
    Save-State $status $summary
    Write-Log "$($status.ToUpperInvariant()): $summary"
    $RunResult = @($status, $summary)
    if ($status -eq 'Failed') { throw $summary }
} catch {
    $message = $_.Exception.Message
    Write-Log "STOPPED: $message"
    $current = $null
    if (Test-Path -LiteralPath $StatePath) { $current = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json }
    if (-not $current -or $current.status -ne 'Failed') { Save-State 'Failed' $message }
    if (-not $RunResult) { $RunResult = @('Failed', $message) }
    throw
} finally {
    # A readiness gate that stops early still removes the credentials, because the attendee gets the VM next.
    if ($Mode -eq 'Verify' -and -not $Manual -and -not $CredentialsRemoved -and [string]$Cfg.RemoveCredentials -in 'AfterGate', 'AfterPrepare') {
        try { Remove-CloudCredential | Out-Null } catch { Write-Log "Couldn't remove the cloud credentials. $($_.Exception.Message)" }
    }
    if ($RunResult) { Write-RunSummary $RunResult[0] $RunResult[1] }
    if ($mutex) {
        if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}
}

# =============================================================================================
# Launcher. Saves the worker and its settings, starts the worker or rejoins a running one, and
# waits for it. Skillable sees the result, where the summary for troubleshooting is, and the
# total elapsed time, or an error if the worker fails.
# =============================================================================================
$ErrorActionPreference = 'Stop'
$LaunchedAt = Get-Date   # The final confirmation reports the total elapsed time from here
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }
$LcaDir     = 'C:\ProgramData\LAB723-lca'
$WorkerPath = Join-Path $LcaDir 'lab723-lca-worker.ps1'
$ConfigPath = Join-Path $LcaDir 'config.json'
$TaskName   = 'LAB723 LCA worker'
$Utf8NoBom  = New-Object Text.UTF8Encoding($false)

function Test-Value($Value) {
    # A token that Skillable didn't replace, including one with a space after the @, isn't a value.
    $text = [string]$Value
    return ($text.Length -gt 0 -and $text -notmatch '^@\s*lab\.')
}

function Invoke-LauncherAz([string[]]$Arguments) {
    # Runs the Azure CLI's Python directly, as the worker does. Returns its output, or $null if it fails.
    $python = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\python.exe'
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& $python -IBm azure.cli @Arguments --only-show-errors 2>$null) } finally { $ErrorActionPreference = $saved }
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($out | ForEach-Object { [string]$_ }) -join "`n")
}

function Initialize-ManualRun {
    # A manual run works in this window, as you: the lab's cloud portal user, signed in to the Azure CLI.
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the LAB723 begin state script in PowerShell as administrator.'
    }
    if (-not (Test-Path -LiteralPath 'C:\Program Files\Microsoft SDKs\Azure\CLI2\python.exe')) {
        throw "The Azure CLI isn't installed. Build the image with LAB723 VM image setup.ps1."
    }
    $json = Invoke-LauncherAz @('account', 'show', '--output', 'json')
    if (-not $json) {
        # Browser sign-in, as attendees do it, reuses an Azure portal sign-in in Edge.
        $null = Invoke-LauncherAz @('config', 'set', 'core.enable_broker_on_windows=false', 'core.login_experience_v2=off')
        Write-Host 'Sign in to the Azure CLI with your lab account: the cloud portal user and its Temporary Access Pass.'
        & 'C:\Program Files\Microsoft SDKs\Azure\CLI2\python.exe' -IBm azure.cli login --output none
        $json = Invoke-LauncherAz @('account', 'show', '--output', 'json')
    }
    if (-not $json) { throw "The Azure CLI isn't signed in. Run az login with your lab account, and then run this script again." }
    $account = $json | ConvertFrom-Json
    if ($account.user.type -ne 'user') {
        throw "The Azure CLI is signed in as $($account.user.type) $($account.user.name). Run az login with your lab account."
    }
    $group = [string]$Settings.ResourceGroup
    if (-not (Test-Value $group)) {
        $list = Invoke-LauncherAz @('group', 'list', '--query', '[].name', '--output', 'tsv')
        $groups = @(([string]$list) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($groups.Count -eq 0) { throw "Your lab account can't see a resource group in subscription $($account.name)." }
        if ($groups.Count -eq 1) {
            $group = $groups[0]
        } else {
            Write-Host 'Resource groups that your lab account can see:'
            for ($i = 0; $i -lt $groups.Count; $i++) { Write-Host "  $($i + 1). $($groups[$i])" }
            $choice = Read-Host 'Number of the lab resource group'
            $index = 0
            if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $groups.Count) { throw 'No resource group was chosen.' }
            $group = $groups[$index - 1]
        }
    }
    return [pscustomobject]@{ TenantId = [string]$account.tenantId; SubscriptionId = [string]$account.id
                              User = [string]$account.user.name; ResourceGroup = $group }
}

function Read-JsonFile([string]$Path) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    return $null
}

function Resolve-LabUser {
    $name = [string]$Settings.LabUser
    if (-not $name) {
        try {
            $owners = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" | ForEach-Object {
                $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
                if ($owner.ReturnValue -eq 0) { $owner.User }
            } | Select-Object -Unique)
            if ($owners.Count -eq 1) { $name = [string]$owners[0] }
        } catch { }
    }
    if (-not $name) {
        $console = [string](Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        if ($console) { $name = $console.Split('\')[-1] }
    }
    if (-not $name -and [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { $name = $env:USERNAME }
    if (-not $name) { throw 'No user is signed in to Windows. Turn on automatic sign-in in the image, or set LabUser.' }
    $sid = (New-Object Security.Principal.NTAccount($name)).Translate([Security.Principal.SecurityIdentifier]).Value
    $profilePath = [string](Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'").LocalPath
    if (-not $profilePath) { throw "There's no profile folder for $name yet. Sign in as $name once." }
    return [pscustomobject]@{ Name = $name; Sid = $sid; Profile = $profilePath }
}

function Start-WorkerTask([string]$RunId, [string]$Launched) {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Prepare -ConfigPath "{1}" -RunId {2} -LaunchedAt {3}' -f
                 $WorkerPath, $ConfigPath, $RunId, $Launched
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew `
                                                 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $taskSettings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
}

function Set-LabOutputs($State) {
    # Lab variables that the instructions can use, such as aksClusterName, when Skillable provides Set-LabVariable here.
    $map = [ordered]@{ aksClusterName = 'clusterName'; acrLoginServer = 'registryLoginServer'; storageAccountName = 'storageName' }
    foreach ($variable in $map.Keys) {
        $value = [string]$State.lab.($map[$variable])
        if (-not $value) { continue }
        try { Set-LabVariable -Name $variable -Value $value } catch { return }
    }
}

function Get-CredentialProblem {
    # Why the CLOUD CREDENTIALS section at the top of this script doesn't give the worker the service principal, if it
    # doesn't.
    $section = 'the CLOUD CREDENTIALS section at the top of this script'
    if ($CloudSubscription.Count -eq 0) {
        return ("$section is still commented out, so there's no service principal to sign in as. A cloud subscription pool " +
                'admin must delete the # at the start of its four lines and the space after each @, and save the script')
    }
    $problems = @(foreach ($name in 'TenantId', 'SubscriptionId', 'ClientId', 'ClientSecret') {
        $value = [string]$CloudSubscription[$name]
        if (-not $CloudSubscription.ContainsKey($name)) { "the $name line is still commented out" }
        elseif ($value -match '^@\s+lab\.') { "the $name token still has a space after the @" }
        elseif ($value -match '^@\s*lab\.') { "the $name token wasn't replaced, so check that the lab profile has a cloud subscription pool" }
        elseif (-not $value) { "$name is empty" }
    })
    if ($problems.Count -gt 0) { return "in $section, $($problems -join '; ')" }
    return ''
}

function Write-RunEnd($State) {
    # The last lines of the final confirmation: the summary in the lab folder, and the run's total elapsed time.
    if ($State -and $State.setupLog) { Write-Output "Summary for troubleshooting: $($State.setupLog)" }
    if ($State -and $State.elapsed) { Write-Output "Total elapsed time: $($State.elapsed)." }
}

function Get-RunEndText($State) {
    # The same, as the end of an error message.
    $parts = @()
    if ($State -and $State.elapsed) { $parts += "Total elapsed time: $($State.elapsed)." }
    if ($State -and $State.setupLog) { $parts += "Summary for troubleshooting: $($State.setupLog)" }
    return ($parts -join ' ')
}

function Clear-ConfigSecrets {
    # The worker removes the secrets from disk when it starts. This covers a run that rejoined a running worker.
    $current = Read-JsonFile $ConfigPath
    if ($current -and ($current.ClientSecret -or $current.SourcePassword)) {
        $current.ClientSecret = ''
        $current.SourcePassword = ''
        [IO.File]::WriteAllText($ConfigPath, (ConvertTo-Json -InputObject $current -Depth 3), $Utf8NoBom)
    }
}

$Manual = [bool]$Settings.Manual
if ($Manual) {
    $manualContext = Initialize-ManualRun
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $labUser = [pscustomobject]@{ Name = $env:USERNAME; Sid = $me.User.Value; Profile = $env:USERPROFILE }
} else {
    $labUser = Resolve-LabUser
}
New-Item -ItemType Directory -Path $LcaDir -Force | Out-Null
# Only SYSTEM, administrators, and the lab user can open this folder. Its settings file holds the service principal's
# secret only until the worker starts. The worker's Azure CLI profile is in a subfolder that the lab user can't open.
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$aclOutput = & icacls.exe $LcaDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*$($labUser.Sid):(OI)(CI)F" 2>&1
$aclExitCode = $LASTEXITCODE
$ErrorActionPreference = $saved
if ($aclExitCode -ne 0) {
    throw "Couldn't restrict access to $LcaDir, so no settings were saved. icacls: $(($aclOutput | Out-String).Trim())"
}

if ($Manual) {
    # No service principal: the worker uses your own Azure CLI sign-in, so there are no credentials to remove.
    $Settings.TenantId = $manualContext.TenantId
    $Settings.SubscriptionId = $manualContext.SubscriptionId
    $Settings.ClientId = ''
    $Settings.ClientSecret = ''
    $Settings.ResourceGroup = $manualContext.ResourceGroup
    $Settings.PortalUser = $manualContext.User
    $Settings.RemoveCredentials = 'Never'
} elseif ($Mode -eq 'Prepare') {
    # The service principal comes from the CLOUD CREDENTIALS section at the top of this script.
    $problem = Get-CredentialProblem
    if ($problem) { throw "LAB723 prepare can't start: $problem. ""LAB723 LCA runbook.md"" has the details." }
} else {
    # The readiness gate needs no secret. It checks the IDs that the last prepare run used.
    $previous = Read-JsonFile $ConfigPath
    foreach ($name in 'TenantId', 'SubscriptionId', 'ClientId') {
        if ($previous -and -not (Test-Value $Settings[$name])) { $Settings[$name] = [string]$previous.$name }
    }
}

$config = [ordered]@{}
foreach ($key in $Settings.Keys) { $config[$key] = $Settings[$key] }
$config['LabUser'] = $labUser.Name
$config['LabProfile'] = $labUser.Profile
$workerText = $Worker.ToString()
$sha = [Security.Cryptography.SHA256]::Create()
$config['Signature'] = [BitConverter]::ToString($sha.ComputeHash(
    $Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $config -Depth 3) + $workerText))).Replace('-', '')

try {
    [IO.File]::WriteAllText($ConfigPath, (ConvertTo-Json -InputObject $config -Depth 3), $Utf8NoBom)
    [IO.File]::WriteAllText($WorkerPath, $workerText, $Utf8NoBom)

    if ($Mode -eq 'Verify') {
        $launched = $LaunchedAt.ToString('o')
        try {
            & $WorkerPath -Mode Verify -ConfigPath $ConfigPath -RunId ([guid]::NewGuid().ToString()) -LaunchedAt $launched
        } catch {
            throw ("LAB723 readiness gate failed. $($_.Exception.Message) " + (Get-RunEndText (Read-JsonFile (Join-Path $LcaDir 'state-verify.json')))).Trim()
        }
        Write-Output 'LAB723 readiness gate passed.'
        Write-RunEnd (Read-JsonFile (Join-Path $LcaDir 'state-verify.json'))
        return
    }

    if ($Manual) {
        # A manual run works in this window, so that the Azure CLI uses your sign-in.
        $statePath = Join-Path $LcaDir 'state-prepare.json'
        $state = Read-JsonFile $statePath
        if ($state -and $state.status -eq 'Running' -and (Get-Process -Id ([int]$state.processId) -ErrorAction SilentlyContinue)) {
            throw 'The prepare LCA is still running in this VM. Wait for it to finish, and then run this script again.'
        }
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        Write-Host ("LAB723 begin state, by hand: resource group $($Settings.ResourceGroup), subscription " +
                    "$($Settings.SubscriptionId), as $($Settings.PortalUser). It takes 30 to 45 minutes. Log folder: $LcaDir")
        $workerError = ''
        try {
            & $WorkerPath -Mode Prepare -ConfigPath $ConfigPath -RunId ([guid]::NewGuid().ToString()) -LaunchedAt $LaunchedAt.ToString('o')
        } catch {
            $workerError = $_.Exception.Message
        }
        $state = Read-JsonFile $statePath
        $message = if ($state) { [string]$state.message } elseif ($workerError) { $workerError } else { "No result. Log folder: $LcaDir" }
        switch ([string]$state.status) {
            'Succeeded'  { Write-Output "LAB723 begin state is ready. $message" }
            'Incomplete' { Write-Output "LAB723 begin state finished, but the environment isn't complete. $message" }
            default      { throw ("LAB723 begin state failed. $message " + (Get-RunEndText $state)).Trim() }
        }
        if ($state -and $state.lab -and $state.lab.templateDeployment) {
            Write-Output ("Resource template deployment: $($state.lab.templateDeployment) in $($Settings.ResourceGroup). To review it, " +
                          "run az deployment group show --resource-group $($Settings.ResourceGroup) --name $($state.lab.templateDeployment)")
        }
        Write-RunEnd $state
        return
    }

    # Only a clean run with the same settings and script is skipped. Incomplete runs are repeated in full.
    $statePath = Join-Path $LcaDir 'state-prepare.json'
    $state = Read-JsonFile $statePath
    if ($state -and $state.status -eq 'Succeeded' -and $state.signature -eq $config['Signature']) {
        Set-LabOutputs $state
        Write-Output "LAB723 prepare had already finished. $($state.message)"
        Write-RunEnd $state
        return
    }
    $running = $state -and $state.status -eq 'Running' -and (Get-Process -Id ([int]$state.processId) -ErrorAction SilentlyContinue)
    if ($running) {
        $runId = [string]$state.runId
    } else {
        $runId = [guid]::NewGuid().ToString()
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        $useTask = $true
        try { Start-WorkerTask $runId $LaunchedAt.ToString('o') } catch { $useTask = $false }
        if (-not $useTask) {
            # Without permission to create a SYSTEM task, run the worker in this process instead.
            try { & $WorkerPath -Mode Prepare -ConfigPath $ConfigPath -RunId $runId -LaunchedAt $LaunchedAt.ToString('o') } catch { }
        }
    }

    $deadline = (Get-Date).AddMinutes([int]$Settings.WaitMinutes)
    $waitStart = Get-Date
    while ($true) {
        $state = Read-JsonFile $statePath
        if ($state -and $state.runId -eq $runId -and $state.status -ne 'Running') { break }
        if ((Get-Date) -gt $deadline) {
            throw ("LAB723 prepare is still running after $($Settings.WaitMinutes) minutes. It continues in the background, " +
                   "and a retry of this action waits for it. Log folder: $LcaDir")
        }
        $workerGone = $state -and $state.runId -eq $runId -and -not (Get-Process -Id ([int]$state.processId) -ErrorAction SilentlyContinue)
        $neverStarted = -not $state -and ((Get-Date) - $waitStart).TotalMinutes -gt 3
        if ($workerGone -or $neverStarted) { throw "The LAB723 prepare worker stopped unexpectedly. Log folder: $LcaDir" }
        Start-Sleep -Seconds 15
    }
    switch ($state.status) {
        'Succeeded' {
            Set-LabOutputs $state
            Write-Output "LAB723 prepare succeeded. $($state.message)"
            Write-RunEnd $state
        }
        'Incomplete' {
            Set-LabOutputs $state
            Write-Output "LAB723 prepare finished, but the environment isn't complete. $($state.message)"
            Write-RunEnd $state
        }
        default { throw ("LAB723 prepare failed. $($state.message) " + (Get-RunEndText $state)).Trim() }
    }
} finally {
    Clear-ConfigSecrets
}
