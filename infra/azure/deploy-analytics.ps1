<#
.SYNOPSIS
Despliega en Azure todos los servicios de la analítica (Persona 2).

.DESCRIPTION
Crea o actualiza, en un grupo de recursos:
  - Event Hubs (match-events y match-insights) y Blob Storage (main.bicep y analytics.bicep).
  - Log Analytics, Azure Container Registry, una identidad administrada y sus roles.
  - Un entorno de Azure Container Apps con la API, la interfaz, el procesador continuo
    y el trabajo que repite un partido de Supabase en Event Hubs.

Pasos: comprueba herramientas y región, despliega la infraestructura (fase 1),
construye y publica las imágenes, opcionalmente carga los datos ficticios en
Supabase y despliega las aplicaciones (fase 2).

La cadena de Supabase se lee de $env:SUPABASE_DB_URL o se pide sin mostrarla.
Viaja a Azure en un archivo temporal que se borra al terminar; nunca se imprime.

.EXAMPLE
$env:SUPABASE_DB_URL = Read-Host 'Cadena del Session pooler de Supabase'
./infra/azure/deploy-analytics.ps1 -ResourceGroup rg-mentox-analytics -Location eastus2 -SeedDatabase

.EXAMPLE
./infra/azure/deploy-analytics.ps1 -ResourceGroup rg-mentox-analytics -WhatIf
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroup,

    [string] $Location = 'eastus2',

    # Región del entorno de Container Apps y sus aplicaciones. Por defecto, -Location.
    # La suscripción admite un solo entorno: para el estadio debe tener GPU T4 (eastus).
    [string] $EnvironmentLocation,

    # Declara el perfil GPU T4 que agregan los scripts de MESSI y Roboflow, para no quitarlo.
    [switch] $GpuWorkloadProfile,

    [ValidatePattern('^[a-z0-9]{3,9}$')]
    [string] $Prefix = 'mentoxp2',

    [ValidateSet('dev', 'test', 'demo')]
    [string] $Environment = 'demo',

    # Etiqueta de las imágenes. Por defecto: commit actual y fecha.
    [string] $ImageTag,

    # Partido que repite el trabajo replay y su velocidad (1 = tiempo real).
    [string] $ReplayMatchId = 'synthetic-analytics-001',
    [ValidateRange(1, 32)]
    [int] $ReplaySpeed = 8,

    # URL del proyecto de Supabase para validar las sesiones de los editores. Por defecto:
    # $env:SUPABASE_URL o SUPABASE_URL de apps/backend/.env.
    [string] $SupabaseUrl,

    # Vídeo MESSI en el contenedor authorized-videos del Storage del despliegue. Vacío: sin estadio.
    [string] $VisionVideoBlobName = 'messi/messi-clean-2x180s-20261026/messi-001/match.mp4',

    # Carga el esquema y los datos ficticios en Supabase antes de la fase 2.
    [switch] $SeedDatabase,

    # No despliega la interfaz.
    [switch] $SkipWeb,

    # Deja encendido el procesador continuo (cuesta cómputo mientras esté encendido).
    [switch] $WorkerOn,

    # Mantiene una réplica de la API (sin arranque en frío, útil el día de la demo).
    [switch] $ApiAlwaysOn,

    # Construye las imágenes en Azure (ACR Tasks) en lugar de Docker local.
    [switch] $UseAcrBuild,

    # Solo la fase 1: infraestructura, sin imágenes ni aplicaciones.
    [switch] $InfraOnly,

    # Borra y vuelve a crear el entorno de Container Apps con sus aplicaciones.
    [switch] $RecreateEnvironment,

    # Muestra qué cambiaría la fase 1. Solo registra proveedores y crea el grupo vacío,
    # que no tienen costo.
    [switch] $WhatIf,

    # No pide confirmación.
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Template = Join-Path $PSScriptRoot 'analytics-platform.bicep'
$Providers = @(
    'Microsoft.App', 'Microsoft.OperationalInsights', 'Microsoft.ContainerRegistry',
    'Microsoft.ManagedIdentity', 'Microsoft.EventHub', 'Microsoft.Storage'
)

function Write-Step([string] $Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Invoke-Az {
    # Ejecuta Azure CLI y falla si devuelve un código distinto de cero.
    $output = & az @args
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI falló: az $($args[0]) $($args[1]) (código $LASTEXITCODE)"
    }
    return $output
}

function Test-AzCommand {
    # Devuelve si el comando tuvo éxito, sin mostrar su salida ni detener el script.
    $ErrorActionPreference = 'Continue'
    & az @args *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-AzQuiet {
    # Salida de un comando opcional; vacía si falla.
    $ErrorActionPreference = 'Continue'
    $output = & az @args 2> $null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return }
    return $output
}

function Test-Docker {
    $ErrorActionPreference = 'Continue'
    & docker info --format '{{.ServerVersion}}' *> $null
    return ($LASTEXITCODE -eq 0)
}

function Wait-Until([scriptblock] $Condition, [string] $What, [int] $Minutes = 20) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while (-not (& $Condition)) {
        if ((Get-Date) -gt $deadline) { throw "Se agotó la espera: $What. Vuelva a ejecutar el script." }
        Write-Host "  esperando $What..."
        Start-Sleep -Seconds 15
    }
}

function Invoke-Native([string] $Command, [string[]] $Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments[0]) falló (código $LASTEXITCODE)"
    }
}

function Push-Image([string] $Image) {
    # ACR a veces corta la respuesta al subir el manifiesto. Repetir es barato:
    # las capas que ya subieron se reutilizan.
    foreach ($attempt in 1..3) {
        & docker push $Image
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -lt 3) {
            Write-Warning "docker push falló (intento $attempt de 3). Se reintenta en 15 segundos."
            Start-Sleep -Seconds 15
        }
    }
    throw "docker push falló tras 3 intentos (código $LASTEXITCODE)"
}

function ConvertFrom-AzJson($Lines) {
    return ($Lines -join "`n") | ConvertFrom-Json
}

function Get-OutputValue($Outputs, [string] $Name) {
    return $Outputs.$Name.value
}

function Write-ParameterFile([hashtable] $Values) {
    $parameters = @{}
    foreach ($key in $Values.Keys) {
        $parameters[$key] = @{ value = $Values[$key] }
    }
    $document = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $parameters
    }
    # Puede contener la cadena de Supabase: va en una carpeta privada. En Windows, la
    # carpeta temporal del usuario ya es privada; en Linux y macOS se limita a 700/600
    # antes de escribir el secreto.
    $directory = Join-Path ([IO.Path]::GetTempPath()) ("mentox-analytics-{0}" -f [guid]::NewGuid())
    New-Item -ItemType Directory -Path $directory | Out-Null
    $path = Join-Path $directory 'parameters.json'
    New-Item -ItemType File -Path $path | Out-Null
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Invoke-Native 'chmod' @('700', $directory)
        Invoke-Native 'chmod' @('600', $path)
    }
    $json = $document | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
    return $path
}

function Remove-ParameterFile([string] $Path) {
    Remove-Item (Split-Path -Parent $Path) -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-PlainText([Security.SecureString] $Secure) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-PythonCommand {
    $venv = Join-Path $RepoRoot '.venv\Scripts\python.exe'
    if (Test-Path $venv) { return $venv }
    $venvUnix = Join-Path $RepoRoot '.venv/bin/python'
    if (Test-Path $venvUnix) { return $venvUnix }
    if (Get-Command python -ErrorAction SilentlyContinue) { return 'python' }
    throw 'No se encontró Python. Cree .venv e instale el backend con el extra db.'
}

# ----- 1. Herramientas --------------------------------------------------------
Write-Step 'Comprobando herramientas'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Falta Azure CLI. En Windows: winget install -e --id Microsoft.AzureCLI (y abra otra terminal).'
}
$useDocker = -not $UseAcrBuild
if ($useDocker -and -not $InfraOnly -and -not $WhatIf) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Falta Docker. Inicie Docker Desktop o use -UseAcrBuild.'
    }
    if (-not (Test-Docker)) {
        throw 'Docker no responde. Inicie Docker Desktop o use -UseAcrBuild.'
    }
}
if (-not (Test-AzCommand bicep version)) {
    Invoke-Az bicep install | Out-Null
}

# ----- 2. Cuenta y suscripción ------------------------------------------------
Write-Step 'Comprobando la sesión de Azure'
if (-not (Test-AzCommand account show --output none)) {
    Write-Host 'No hay sesión. Se abrirá el inicio de sesión de Azure.'
    Invoke-Az login --output none | Out-Null
}
$account = ConvertFrom-AzJson (Invoke-Az account show --output json)
if (-not $EnvironmentLocation) { $EnvironmentLocation = $Location }
# Dos suscripciones pueden llamarse igual (Azure for Students): se muestra también el ID.
Write-Host ("Suscripción: {0} ({1})" -f $account.name, $account.id)
Write-Host ("Grupo: {0} · Región: {1} · Entorno de Container Apps en: {2} · Prefijo: {3} · Entorno: {4}" -f $ResourceGroup, $Location, $EnvironmentLocation, $Prefix, $Environment)
if (-not $Yes -and -not $WhatIf) {
    $answer = Read-Host '¿Desplegar en esta suscripción? Crea recursos con costo (s/N)'
    if ($answer -notmatch '^(s|si|sí|y|yes)$') {
        Write-Host 'Cancelado.'
        exit 1
    }
}

# Azure for Students limita las regiones permitidas con una política.
$allowed = @(Get-AzQuiet policy assignment list --query '[].parameters.listOfAllowedLocations.value[]' --output tsv)
foreach ($region in @($Location, $EnvironmentLocation) | Select-Object -Unique) {
    if ($allowed.Count -gt 0 -and $allowed -notcontains $region) {
        throw ("La región {0} no está permitida en esta suscripción. Regiones permitidas: {1}" -f $region, ($allowed -join ', '))
    }
}

# ----- 3. Supabase ------------------------------------------------------------
$databaseUrl = $env:SUPABASE_DB_URL
if (-not $databaseUrl -and -not $Yes -and -not $InfraOnly -and -not $WhatIf) {
    $secure = Read-Host -AsSecureString 'Cadena del Session pooler de Supabase (Enter para usar solo partidos sintéticos)'
    $databaseUrl = Get-PlainText $secure
}
if ($databaseUrl) {
    if ($databaseUrl -notmatch '^postgres(ql)?://') {
        throw 'La cadena de Supabase debe empezar por postgresql://'
    }
    # Container Apps sale a Internet solo por IPv4. La conexión directa de Supabase
    # (db.<ref>.supabase.co) solo tiene IPv6: la API no podría leer la base.
    $hostMatches = [regex]::Matches($databaseUrl, '@([^@:/?]+)(?::\d+)?(?:/|$)')
    if ($hostMatches.Count -eq 0) { throw 'No se pudo leer el servidor de la cadena de Supabase.' }
    $databaseHost = $hostMatches[$hostMatches.Count - 1].Groups[1].Value
    $ipv4Count = 1
    try {
        $ipv4Count = @([System.Net.Dns]::GetHostAddresses($databaseHost) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }).Count
    }
    catch {
        Write-Warning "No se pudo resolver $databaseHost desde este equipo; no se comprueba si tiene IPv4."
    }
    if ($databaseHost -match '^db\.[a-z0-9]+\.supabase\.co$' -or $ipv4Count -eq 0) {
        throw ("La cadena usa $databaseHost, que solo tiene IPv6, y Azure Container Apps sale por IPv4. " +
            'Copie la del Session pooler en Supabase: Connect > Direct > Session pooler (servidor ...pooler.supabase.com, usuario postgres.<ref>).')
    }
    Write-Host "Supabase: configurado con $databaseHost (la cadena no se muestra)."
}
else {
    Write-Host 'Supabase: no configurado. La API usará los partidos sintéticos y no se crea el trabajo replay.'
    if ($SeedDatabase) { throw '-SeedDatabase necesita la cadena de Supabase.' }
}

# La revisión editorial valida las sesiones de Supabase Auth del proyecto. La URL no es secreta.
if (-not $SupabaseUrl) { $SupabaseUrl = $env:SUPABASE_URL }
if (-not $SupabaseUrl) {
    $backendEnv = Join-Path $RepoRoot 'apps/backend/.env'
    if (Test-Path -LiteralPath $backendEnv) {
        $line = Get-Content -LiteralPath $backendEnv | Where-Object { $_ -match '^\s*SUPABASE_URL\s*=' } | Select-Object -First 1
        if ($line) { $SupabaseUrl = ($line -replace '^\s*SUPABASE_URL\s*=\s*', '').Trim().Trim('"', "'") }
    }
}
if ($SupabaseUrl) {
    if ($SupabaseUrl -notmatch '^https://[A-Za-z0-9.-]+/?$') {
        throw 'SUPABASE_URL debe ser la URL del proyecto, por ejemplo https://<ref>.supabase.co'
    }
    $SupabaseUrl = $SupabaseUrl.TrimEnd('/')
    Write-Host "Revisión editorial: valida las sesiones de $SupabaseUrl."
}
else {
    Write-Warning 'Sin SUPABASE_URL: la revisión editorial de la API responderá 503.'
}

# Un ajuste que la API ya usa en local: primero la terminal, después apps/backend/.env.
function Get-BackendSetting([string] $Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value) { return $value }
    $backendEnv = Join-Path $RepoRoot 'apps/backend/.env'
    if (-not (Test-Path -LiteralPath $backendEnv)) { return '' }
    $line = Get-Content -LiteralPath $backendEnv | Where-Object { $_ -match "^\s*$Name\s*=" } | Select-Object -First 1
    if (-not $line) { return '' }
    return ($line -replace "^\s*$Name\s*=\s*", '').Trim().Trim('"', "'")
}

# El estadio exige Roboflow y TeamSpotting (servicios de Damon). Las claves viajan solo en el
# archivo temporal de parámetros y quedan como secretos de Container Apps; nunca se muestran.
$stadiumModels = @{
    roboflowEndpoint     = Get-BackendSetting 'ROBOFLOW_SUITE_ENDPOINT'
    roboflowApiKey       = Get-BackendSetting 'ROBOFLOW_SUITE_API_KEY'
    teamspottingEndpoint = Get-BackendSetting 'SOCCERNET_ENDPOINT'
    teamspottingApiKey   = Get-BackendSetting 'SOCCERNET_API_KEY'
}
if (-not $VisionVideoBlobName) {
    Write-Host 'Estadio: no configurado. Partido muestra la cancha sintética.'
}
elseif (@($stadiumModels.Values | Where-Object { -not $_ }).Count -gt 0) {
    Write-Warning 'Faltan ROBOFLOW_SUITE_* o SOCCERNET_* (terminal o apps/backend/.env): el vídeo del estadio no podrá reproducirse.'
}
else {
    Write-Host 'Estadio: vídeo MESSI con Roboflow y TeamSpotting.'
}

# ----- 4. Proveedores y grupo -------------------------------------------------
Write-Step 'Registrando proveedores de recursos'
foreach ($provider in $Providers) {
    $state = Invoke-Az provider show --namespace $provider --query registrationState --output tsv
    if ($state -ne 'Registered') {
        Write-Host "Registrando $provider (puede tardar unos minutos)..."
        Invoke-Az provider register --namespace $provider --wait | Out-Null
    }
}

Write-Step "Grupo de recursos $ResourceGroup"
$groupExists = Invoke-Az group exists --name $ResourceGroup
if ($groupExists -ne 'true') {
    Invoke-Az group create --name $ResourceGroup --location $Location --tags project=mentox-premier-league workload=analytics --output none | Out-Null
}

# El entorno de Container Apps debe estar en modo WorkloadProfiles y activo. Se
# reemplaza, después de confirmar, si está en modo Express (no admite el trabajo
# replay), si Azure suspendió su cómputo (ManagedClusterSuspended) o si es el de
# nombre anterior. Las aplicaciones no guardan datos propios y se vuelven a crear.
$environmentName = "cae-$Prefix-$Environment-wp"
$legacyEnvironmentName = "cae-$Prefix-$Environment"
$subscriptionId = $account.id

function Get-EnvironmentUrl([string] $Name) {
    return "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup" +
        "/providers/Microsoft.App/managedEnvironments/${Name}?api-version=2026-07-01"
}

function Get-EnvironmentProblem([string] $Name) {
    # Devuelve por qué hay que reemplazar el entorno, o nada si no existe o está bien.
    $existing = Get-AzQuiet rest --method get --url (Get-EnvironmentUrl $Name) --output json
    if (-not $existing) { return }
    if ($Name -eq $legacyEnvironmentName) { return 'es el entorno de un despliegue anterior' }
    $resource = ConvertFrom-AzJson $existing
    # Azure no mueve un entorno de región: hay que crearlo de nuevo donde se pide.
    $current = ($resource.location -replace '\s', '').ToLowerInvariant()
    if ($current -ne $EnvironmentLocation.ToLowerInvariant()) {
        return "está en $current y se pidió $EnvironmentLocation"
    }
    $properties = $resource.properties
    if ($properties.PSObject.Properties['environmentMode'] -and $properties.environmentMode -eq 'Express') {
        return 'está en modo Express, que no admite el trabajo replay'
    }
    if ($RecreateEnvironment) { return 'se pidió recrearlo con -RecreateEnvironment' }
    if (Test-EnvironmentSuspended $Name) { return 'Azure suspendió su cómputo (ManagedClusterSuspended)' }
}

function Test-EnvironmentSuspended([string] $Name) {
    $ErrorActionPreference = 'Continue'
    $apps = @(Get-AzQuiet containerapp list --resource-group $ResourceGroup `
            --query "[?ends_with(properties.managedEnvironmentId, '/$Name')].name" --output tsv)
    if ($apps.Count -eq 0) { return $false }
    $answer = (& az containerapp revision list --name $apps[0] --resource-group $ResourceGroup --output none 2>&1) | Out-String
    return ($answer -match 'ManagedClusterSuspended')
}

function Remove-ContainerAppsEnvironment([string] $Name) {
    # Los borrados se lanzan sin esperar y luego se comprueba que terminaron:
    # Microsoft.App a veces responde GatewayTimeout aunque el borrado siga.
    Write-Step "Retirando $Name"
    $query = "[?ends_with(properties.managedEnvironmentId, '/$Name')].name"
    $jobQuery = "[?ends_with(properties.environmentId, '/$Name')].name"
    foreach ($app in @(Get-AzQuiet containerapp list --resource-group $ResourceGroup --query $query --output tsv)) {
        Write-Host "Borrando la aplicación $app..."
        [void](Test-AzCommand containerapp delete --name $app --resource-group $ResourceGroup --yes --no-wait)
    }
    foreach ($job in @(Get-AzQuiet containerapp job list --resource-group $ResourceGroup --query $jobQuery --output tsv)) {
        Write-Host "Borrando el trabajo $job..."
        [void](Test-AzCommand containerapp job delete --name $job --resource-group $ResourceGroup --yes --no-wait)
    }
    Wait-Until -What 'el borrado de las aplicaciones' -Condition {
        @(Get-AzQuiet containerapp list --resource-group $ResourceGroup --query $query --output tsv).Count -eq 0 -and
        @(Get-AzQuiet containerapp job list --resource-group $ResourceGroup --query $jobQuery --output tsv).Count -eq 0
    }
    Write-Host "Borrando el entorno $Name (tarda unos minutos)..."
    [void](Test-AzCommand containerapp env delete --name $Name --resource-group $ResourceGroup --yes --no-wait)
    $url = Get-EnvironmentUrl $Name
    # Un entorno con perfiles de carga puede tardar más de 20 minutos en desaparecer.
    Wait-Until -What "el borrado de $Name" -Minutes 45 -Condition {
        -not (Get-AzQuiet rest --method get --url $url --output json)
    }
}

foreach ($candidate in @($legacyEnvironmentName, $environmentName)) {
    $problem = Get-EnvironmentProblem $candidate
    if (-not $problem) { continue }
    Write-Warning "Hay que reemplazar el entorno ${candidate}: $problem. El nuevo es $environmentName, en modo WorkloadProfiles."
    if ($WhatIf) {
        Write-Host 'La vista previa no lo cambia. El despliegue real lo reemplazará.'
        continue
    }
    if (-not $Yes) {
        $answer = Read-Host "¿Borrar $candidate con sus aplicaciones? Se vuelven a crear después (s/N)"
        if ($answer -notmatch '^(s|si|sí|y|yes)$') {
            Write-Host 'Cancelado.'
            exit 1
        }
    }
    Remove-ContainerAppsEnvironment $candidate
}

$baseParameters = @{
    projectPrefix       = $Prefix
    environmentName     = $Environment
    location            = $Location
    environmentLocation = $EnvironmentLocation
    gpuWorkloadProfile  = [bool] $GpuWorkloadProfile
}

# ----- 5. Fase 1: infraestructura ---------------------------------------------
if ($WhatIf) {
    Write-Step 'What-if de la fase 1 (no crea nada)'
    $file = Write-ParameterFile ($baseParameters + @{ deployApps = $false })
    try {
        Invoke-Native 'az' @('deployment', 'group', 'what-if', '--resource-group', $ResourceGroup,
            '--template-file', $Template, '--parameters', "@$file")
    }
    finally {
        Remove-ParameterFile $file
    }
    exit 0
}

Write-Step 'Fase 1: Event Hubs, Storage, registro, identidad y entorno de Container Apps'
$file = Write-ParameterFile ($baseParameters + @{ deployApps = $false })
try {
    $infra = ConvertFrom-AzJson (Invoke-Az deployment group create --name 'mentox-analytics-infra' `
            --resource-group $ResourceGroup --template-file $Template --parameters "@$file" `
            --query properties.outputs --output json)
}
finally {
    Remove-ParameterFile $file
}
$registryName = Get-OutputValue $infra 'registryName'
$loginServer = Get-OutputValue $infra 'registryLoginServer'
Write-Host "Registro: $loginServer"

if ($InfraOnly) {
    Write-Host 'Fase 1 terminada (-InfraOnly).'
    exit 0
}

# ----- 6. Imágenes ------------------------------------------------------------
if (-not $ImageTag) {
    $commit = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $ErrorActionPreference = 'Continue'
        $commit = (& git -C $RepoRoot rev-parse --short HEAD 2> $null)
        $ErrorActionPreference = 'Stop'
    }
    if (-not $commit) { $commit = 'local' }
    $ImageTag = '{0}-{1}' -f $commit, (Get-Date -Format 'yyyyMMddHHmmss')
}
$apiImage = "$loginServer/match-intelligence-api:$ImageTag"
$webImage = "$loginServer/match-intelligence-web:$ImageTag"
# La API se construye desde la raíz: copia también los resultados de visión de
# Persona 1 que están en docs/ (el .dockerignore de la raíz limita lo que se envía).
$builds = @(@{
        Image = $apiImage; Name = "match-intelligence-api:$ImageTag"; Context = $RepoRoot
        File = (Join-Path $RepoRoot 'apps/backend/Dockerfile')
    })
if (-not $SkipWeb) {
    $frontend = Join-Path $RepoRoot 'apps/frontend'
    $builds += @{
        Image = $webImage; Name = "match-intelligence-web:$ImageTag"; Context = $frontend
        File = (Join-Path $frontend 'Dockerfile')
    }
}

Write-Step "Construyendo y publicando imágenes ($ImageTag)"
if ($useDocker) {
    Invoke-Az acr login --name $registryName | Out-Null
}
foreach ($build in $builds) {
    if ($useDocker) {
        Invoke-Native 'docker' @('build', '--platform', 'linux/amd64', '--file', $build.File,
            '--tag', $build.Image, $build.Context)
        Push-Image $build.Image
    }
    else {
        # Algunas suscripciones de estudiante no permiten ACR Tasks; en ese caso use Docker.
        Invoke-Native 'az' @('acr', 'build', '--registry', $registryName, '--image', $build.Name,
            '--platform', 'linux/amd64', '--file', $build.File, $build.Context)
    }
}

# ----- 7. Datos ficticios -----------------------------------------------------
if ($SeedDatabase) {
    Write-Step 'Cargando el esquema y los datos ficticios en Supabase'
    $python = Get-PythonCommand
    $previous = $env:SUPABASE_DB_URL
    $env:SUPABASE_DB_URL = $databaseUrl
    try {
        Invoke-Native $python @((Join-Path $RepoRoot 'apps/backend/scripts/supabase_seed.py'), '--schema')
    }
    finally {
        $env:SUPABASE_DB_URL = $previous
    }
}

# ----- 8. Fase 2: aplicaciones -------------------------------------------------
Write-Step 'Fase 2: API, interfaz, procesador continuo y trabajo replay'
$appParameters = $baseParameters + @{
    deployApps     = $true
    apiImage       = $apiImage
    webImage       = $(if ($SkipWeb) { '' } else { $webImage })
    supabaseDbUrl  = $(if ($databaseUrl) { $databaseUrl } else { '' })
    supabaseUrl    = $(if ($SupabaseUrl) { $SupabaseUrl } else { '' })
    visionVideoBlobName = $VisionVideoBlobName
    apiMinReplicas = $(if ($ApiAlwaysOn) { 1 } else { 0 })
    workerReplicas = $(if ($WorkerOn) { 1 } else { 0 })
    replayMatchId  = $ReplayMatchId
    replaySpeed    = [string] $ReplaySpeed
} + $stadiumModels
$file = Write-ParameterFile $appParameters
try {
    $apps = ConvertFrom-AzJson (Invoke-Az deployment group create --name 'mentox-analytics-apps' `
            --resource-group $ResourceGroup --template-file $Template --parameters "@$file" `
            --query properties.outputs --output json)
}
finally {
    Remove-ParameterFile $file
}
$apiUrl = Get-OutputValue $apps 'apiUrl'
$webUrl = Get-OutputValue $apps 'webUrl'
$workerApp = Get-OutputValue $apps 'workerAppName'
$replayJob = Get-OutputValue $apps 'replayJobName'

# ----- 9. Verificación ----------------------------------------------------------
Write-Step 'Esperando a la API (el primer arranque puede tardar un par de minutos)'
$loaded = $null
for ($attempt = 1; $attempt -le 18; $attempt++) {
    try {
        $loaded = Invoke-RestMethod -Uri "$apiUrl/api/v1/matches" -TimeoutSec 60
        break
    }
    catch {
        Start-Sleep -Seconds 10
    }
}
if ($null -eq $loaded) {
    Write-Warning "La API todavía no responde. Revise: az containerapp logs show -n $(Get-OutputValue $apps 'apiAppName') -g $ResourceGroup"
}
else {
    Write-Host ('Partidos cargados: {0}' -f (($loaded | ForEach-Object { $_.match_id }) -join ', '))
}

if ($null -ne $loaded) {
    # Azure puede suspender el cómputo de un entorno nuevo poco después de arrancar.
    Write-Step 'Comprobando que el entorno sigue activo (90 s)'
    Start-Sleep -Seconds 90
    if (Test-EnvironmentSuspended $environmentName) {
        Write-Warning ("Azure suspendió el cómputo de $environmentName (ManagedClusterSuspended). " +
            "Vuelva a ejecutar el script con -RecreateEnvironment; si se repite, consulte la guía.")
    }
    else {
        Write-Host 'El entorno sigue activo.'
    }
}

# ----- 10. Resumen ----------------------------------------------------------------
Write-Step 'Listo'
Write-Host "API:        $apiUrl  (documentación en $apiUrl/docs)"
if ($webUrl) { Write-Host "Interfaz:   $webUrl" }
Write-Host "Imágenes:   $ImageTag"
Write-Host ''
Write-Host 'Comandos útiles:'
Write-Host "  Encender el procesador:  az containerapp update -n $workerApp -g $ResourceGroup --min-replicas 1 --max-replicas 1"
Write-Host "  Apagar el procesador:    az containerapp update -n $workerApp -g $ResourceGroup --min-replicas 0 --max-replicas 1"
if ($databaseUrl) {
    Write-Host "  Repetir un partido:      az containerapp job start -n $replayJob -g $ResourceGroup"
}
Write-Host "  Ver registros:           az containerapp logs show -n $workerApp -g $ResourceGroup --follow"
Write-Host "  Borrar todo:             ./infra/azure/remove-analytics.ps1 -ResourceGroup $ResourceGroup"
Write-Host ''
Write-Host 'Costo aproximado: cerca de 1 USD al día con el procesador apagado (Event Hubs Standard y el registro),'
Write-Host 'hasta unos 45 USD al mes con todo encendido. Borre el grupo al terminar la demo para cuidar los créditos.'
