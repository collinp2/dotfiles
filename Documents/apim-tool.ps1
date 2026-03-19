<#
.SYNOPSIS
    Export and import Azure API Management APIs with policies and named values.

.DESCRIPTION
    Export an API (definition, policies, named values) into a ZIP file, or import
    a previously exported ZIP into another APIM environment. Designed for
    dev -> test -> prod promotion workflows.

.EXAMPLE
    # Export — auto-detect APIM instance from current login
    .\apim-tool.ps1 export -ApiId "my-api" -OutputFile "my-api-export.zip"

    # Export — explicit target (useful when multiple APIM instances exist)
    .\apim-tool.ps1 export `
      -ApiId "my-api" `
      -OutputFile "my-api-export.zip" `
      -SubscriptionId "abc-123" `
      -ResourceGroup "rg-dev" `
      -ServiceName "my-apim-dev"

    # Import — auto-detect target APIM from current login
    .\apim-tool.ps1 import `
      -ZipFile "my-api-export.zip" `
      -ParametersFile "parameters.prod.json"

    # Import — explicit target
    .\apim-tool.ps1 import `
      -ZipFile "my-api-export.zip" `
      -ParametersFile "parameters.prod.json" `
      -SubscriptionId "abc-123" `
      -ResourceGroup "rg-prod" `
      -ServiceName "my-apim-prod"
#>

[CmdletBinding()]
param(
    # Positional mode: export | import
    [Parameter(Position=0, Mandatory=$true)]
    [ValidateSet('export','import')]
    [string]$Mode,

    # --- Shared ---
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$ServiceName,

    # --- Auth (optional; falls back to az CLI) ---
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$TenantId,

    # --- Export ---
    [string]$ApiId,
    [string]$OutputFile,

    # --- Import ---
    [string]$ZipFile,
    [string]$ParametersFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$API_VERSION = '2022-08-01'

# ---------------------------------------------------------------------------
# Helper: colored output
# ---------------------------------------------------------------------------
function Write-Step {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warn','Error')]
        [string]$Level = 'Info'
    )
    $colors = @{ Info='Cyan'; Success='Green'; Warn='Yellow'; Error='Red' }
    $prefix = @{ Info='  >>'; Success='  OK'; Warn='WARN'; Error=' ERR' }
    Write-Host "$($prefix[$Level]) $Message" -ForegroundColor $colors[$Level]
}

# ---------------------------------------------------------------------------
# Helper: Get bearer token (az CLI first, SP fallback)
# ---------------------------------------------------------------------------
function Get-BearerToken {
    param([string]$ClientId, [string]$ClientSecret, [string]$TenantId)

    if (-not $ClientId) {
        # Try az CLI (reliable in Cloud Shell and local installs)
        try {
            $result = & az account get-access-token --resource https://management.azure.com/ 2>$null | ConvertFrom-Json
            if ($result.accessToken) {
                Write-Step "Authenticated via az CLI"
                return $result.accessToken
            }
        } catch { }
        throw "No bearer token available. Run 'az login', or supply -ClientId / -ClientSecret / -TenantId."
    }

    if (-not $TenantId) { throw "-TenantId is required when using service principal auth." }
    if (-not $ClientSecret) { throw "-ClientSecret is required when using service principal auth." }

    Write-Step "Authenticating via service principal..."
    $body = "grant_type=client_credentials&client_id=$([uri]::EscapeDataString($ClientId))&client_secret=$([uri]::EscapeDataString($ClientSecret))&scope=https%3A%2F%2Fmanagement.azure.com%2F.default"
    $resp = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $body
    Write-Step "Authenticated via service principal" -Level Success
    return $resp.access_token
}

# ---------------------------------------------------------------------------
# Helper: Build ARM base URI for APIM
# ---------------------------------------------------------------------------
function Build-ApimBaseUri {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$ServiceName)
    return "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ServiceName"
}

# ---------------------------------------------------------------------------
# Helper: REST wrapper
# ---------------------------------------------------------------------------
function Invoke-ApimApi {
    param(
        [string]$Method = 'GET',
        [string]$Uri,
        [hashtable]$Headers,
        [object]$Body,
        [string]$ContentType = 'application/json',
        [switch]$AllowNotFound,
        [switch]$RawResponse
    )

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = $ContentType
        ErrorAction = 'Stop'
    }
    if ($Body -ne $null) {
        if ($Body -is [string]) {
            $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        } else {
            $params.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
        }
    }

    try {
        $response = Invoke-WebRequest @params
        if ($RawResponse) { return $response }
        $text = [System.Text.Encoding]::UTF8.GetString($response.Content)
        if ($text -and $text.Trim() -ne '') {
            return $text | ConvertFrom-Json
        }
        return $null
    } catch {
        $statusCode = 0
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($AllowNotFound -and ($statusCode -eq 404 -or $statusCode -eq 204)) {
            return $null
        }
        $msg = $_.Exception.Message
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $ms = New-Object System.IO.MemoryStream
            $stream.CopyTo($ms)
            $errBody = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $msg = "$msg`n$errBody"
        } catch { }
        throw "APIM API call failed [$Method $Uri]: $msg"
    }
}

# ---------------------------------------------------------------------------
# Helper: Poll async 202 operation
# ---------------------------------------------------------------------------
function Wait-ForAsyncOperation {
    param(
        [string]$AsyncUrl,
        [hashtable]$Headers,
        [int]$TimeoutSeconds = 120
    )
    Write-Step "Waiting for async operation..."
    $elapsed = 0
    $delay = 5
    while ($elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $delay
        $elapsed += $delay
        $result = Invoke-ApimApi -Uri $AsyncUrl -Headers $Headers -RawResponse
        $status = $null
        try {
            $json = [System.Text.Encoding]::UTF8.GetString($result.Content) | ConvertFrom-Json
            $status = $json.status
        } catch { }

        if ($result.StatusCode -eq 200 -or $result.StatusCode -eq 201) {
            if (-not $status -or $status -eq 'Succeeded') {
                Write-Step "Async operation succeeded" -Level Success
                return $json
            }
            if ($status -eq 'Failed') {
                throw "Async operation failed: $($json | ConvertTo-Json -Compress)"
            }
        }
        if ($result.StatusCode -eq 202) {
            # Still in progress
            Write-Step "  Still in progress... ($elapsed/$TimeoutSeconds s)"
            continue
        }
    }
    throw "Async operation timed out after ${TimeoutSeconds}s"
}

# ---------------------------------------------------------------------------
# Helper: Invoke-PolicyParameterization (export — replace concrete values with tokens)
# ---------------------------------------------------------------------------
function Invoke-PolicyParameterization {
    param([string]$PolicyXml, [string]$ServiceUrl)
    $result = $PolicyXml

    # Replace literal serviceUrl with {{backendUrl}}
    if ($ServiceUrl) {
        $escaped = [regex]::Escape($ServiceUrl.TrimEnd('/'))
        $result = $result -replace $escaped, '{{backendUrl}}'
    }

    # Replace <set-backend-service base-url="..."> value with {{backendUrl}}
    $result = $result -replace '(?i)(<set-backend-service[^>]*\sbase-url=")[^"]*(")', '${1}{{backendUrl}}${2}'

    # Warn about potential hardcoded credentials (but don't replace)
    if ($result -match '(?i)(password|secret|key|token)\s*=\s*"[^"]{8,}"') {
        Write-Step "WARNING: Policy may contain hardcoded credentials — review before sharing the export." -Level Warn
    }

    return $result
}

# ---------------------------------------------------------------------------
# Helper: Invoke-PolicyRehydration (import — replace tokens with real values)
# ---------------------------------------------------------------------------
function Invoke-PolicyRehydration {
    param([string]$PolicyXml, [hashtable]$Params)
    $result = $PolicyXml
    foreach ($key in $Params.Keys) {
        $result = $result -replace [regex]::Escape("{{$key}}"), $Params[$key]
    }
    return $result
}

# ---------------------------------------------------------------------------
# Helper: Sanitize operation name for filename
# ---------------------------------------------------------------------------
function Get-SafeFilename {
    param([string]$Name)
    return ($Name -replace '[^a-zA-Z0-9\-]', '-').Trim('-')
}

# ---------------------------------------------------------------------------
# ZIP helpers (System.IO.Compression, PS 5.1 compatible)
# ---------------------------------------------------------------------------
function New-ExportZip {
    param([string]$Path)
    if (Test-Path $Path) { Remove-Item $Path -Force }
    return [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
}

function Add-ZipEntry {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$EntryName,
        [string]$Content
    )
    $entry = $Zip.CreateEntry($EntryName)
    $stream = $entry.Open()
    $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
    $writer.Write($Content)
    $writer.Close()
    $stream.Close()
}

function Read-ZipEntry {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$EntryName
    )
    $entry = $Zip.GetEntry($EntryName)
    if (-not $entry) { return $null }
    $stream = $entry.Open()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $content = $reader.ReadToEnd()
    $reader.Close()
    $stream.Close()
    return $content
}

function Get-ZipEntries {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$Prefix = ''
    )
    return $Zip.Entries | Where-Object { $_.FullName -like "$Prefix*" } | ForEach-Object { $_.FullName }
}

# ---------------------------------------------------------------------------
# EXPORT
# ---------------------------------------------------------------------------
function Export-Api {
    param(
        [string]$Token,
        [string]$BaseUri,
        [string]$ApiId,
        [string]$OutputFile
    )

    $headers = @{ Authorization = "Bearer $Token"; 'If-Match' = '*' }

    # --- 1. Get API metadata ---
    Write-Step "Fetching API metadata for '$ApiId'..."
    $apiMeta = Invoke-ApimApi -Uri "$BaseUri/apis/$($ApiId)?api-version=$API_VERSION" -Headers $headers
    $serviceUrl = $apiMeta.properties.serviceUrl
    $displayName = $apiMeta.properties.displayName
    $apiPath     = $apiMeta.properties.path
    $protocols   = $apiMeta.properties.protocols

    Write-Step "  Display name : $displayName"
    Write-Step "  Path         : /$apiPath"
    Write-Step "  Backend URL  : $serviceUrl"

    # --- 2. Export OpenAPI definition ---
    Write-Step "Exporting OpenAPI definition..."
    $exportHeaders = $headers.Clone()
    $exportHeaders['Accept'] = 'application/vnd.oai.openapi+json'
    $defUri = "$BaseUri/apis/$($ApiId)?export=true&format=openapi&api-version=$API_VERSION"
    $definition = Invoke-ApimApi -Uri $defUri -Headers $exportHeaders
    $definitionJson = $definition | ConvertTo-Json -Depth 20

    # --- 3. Get API-level policy ---
    Write-Step "Fetching API-level policy..."
    $policyUri = "$BaseUri/apis/$($ApiId)/policies/policy?format=rawxml&api-version=$API_VERSION"
    $policyResp = Invoke-ApimApi -Uri $policyUri -Headers $headers -AllowNotFound
    $apiPolicyXml = $null
    if ($policyResp -and $policyResp.properties -and $policyResp.properties.value) {
        $apiPolicyXml = Invoke-PolicyParameterization -PolicyXml $policyResp.properties.value -ServiceUrl $serviceUrl
        Write-Step "  API policy found and parameterized"
    } else {
        Write-Step "  No API-level policy found — skipping"
    }

    # --- 4. Get operations (paginated) ---
    Write-Step "Fetching operations..."
    $operations = @()
    $nextLink = "$BaseUri/apis/$($ApiId)/operations?api-version=$API_VERSION"
    while ($nextLink) {
        $page = Invoke-ApimApi -Uri $nextLink -Headers $headers
        $operations += $page.value
        $nextLink = $page.nextLink
        if ($nextLink -and -not $nextLink.StartsWith('http')) {
            $nextLink = "https://management.azure.com$nextLink"
        }
    }
    Write-Step "  Found $($operations.Count) operations"

    # --- 5. Get per-operation policies ---
    $operationPolicies = @{}
    foreach ($op in $operations) {
        $opId   = $op.name
        $opName = $op.properties.displayName
        $opPolicyUri = "$BaseUri/apis/$($ApiId)/operations/$opId/policies/policy?format=rawxml&api-version=$API_VERSION"
        $opPolicy = Invoke-ApimApi -Uri $opPolicyUri -Headers $headers -AllowNotFound
        if ($opPolicy -and $opPolicy.properties -and $opPolicy.properties.value) {
            $xml = Invoke-PolicyParameterization -PolicyXml $opPolicy.properties.value -ServiceUrl $serviceUrl
            $safeName = Get-SafeFilename -Name $opId
            $operationPolicies[$safeName] = @{ xml = $xml; displayName = $opName; operationId = $opId }
            Write-Step "  Policy found for operation: $opName"
        }
    }

    # --- 6. Collect named values referenced in policies ---
    Write-Step "Scanning policies for named value references..."
    $allPolicies = @()
    if ($apiPolicyXml) { $allPolicies += $apiPolicyXml }
    foreach ($entry in $operationPolicies.Values) { $allPolicies += $entry.xml }
    $policyConcat = $allPolicies -join "`n"

    # Find all {{namedValueName}} references
    $nvMatches = [regex]::Matches($policyConcat, '\{\{([^}]+)\}\}')
    $referencedNvNames = @{}
    foreach ($m in $nvMatches) {
        $name = $m.Groups[1].Value
        # Skip our parameterization tokens
        if ($name -ne 'backendUrl') {
            $referencedNvNames[$name] = $true
        }
    }

    Write-Step "Fetching named values metadata..."
    $allNvPage = "$BaseUri/namedValues?api-version=$API_VERSION"
    $allNvs = @()
    while ($allNvPage) {
        $nvPage = Invoke-ApimApi -Uri $allNvPage -Headers $headers
        $allNvs += $nvPage.value
        $allNvPage = $nvPage.nextLink
        if ($allNvPage -and -not $allNvPage.StartsWith('http')) {
            $allNvPage = "https://management.azure.com$allNvPage"
        }
    }

    $namedValuesExport = @()
    foreach ($nv in $allNvs) {
        $nvName = $nv.properties.displayName
        if ($referencedNvNames.ContainsKey($nvName) -or $referencedNvNames.ContainsKey($nv.name)) {
            $namedValuesExport += @{
                name        = $nv.name
                displayName = $nv.properties.displayName
                secret      = [bool]$nv.properties.secret
                tags        = $nv.properties.tags
            }
            $flag = if ($nv.properties.secret) { " [SECRET - value not exported]" } else { "" }
            Write-Step "  Named value: $($nv.properties.displayName)$flag"
        }
    }

    # --- 7. Build parameters template ---
    $paramsTemplate = [ordered]@{
        '_comment'   = 'Fill in values for the target environment. Remove this comment before use.'
        backendUrl   = if ($serviceUrl) { $serviceUrl } else { 'FILL_ME_IN' }
        namedValues  = [ordered]@{}
    }
    foreach ($nv in $namedValuesExport) {
        $paramsTemplate.namedValues[$nv.displayName] = if ($nv.secret) { 'FILL_ME_IN_SECRET' } else { 'FILL_ME_IN' }
    }

    # --- 8. Build manifest ---
    $manifest = [ordered]@{
        exportVersion = '1.0'
        exportedAt    = (Get-Date -Format 'o')
        source        = [ordered]@{
            subscriptionId = $script:SubscriptionId
            resourceGroup  = $script:ResourceGroup
            serviceName    = $script:ServiceName
            apiId          = $ApiId
        }
        api           = [ordered]@{
            displayName = $displayName
            path        = $apiPath
            protocols   = $protocols
            serviceUrl  = $serviceUrl
        }
        files         = [ordered]@{
            definition            = 'definition.json'
            apiPolicy             = if ($apiPolicyXml) { 'api-policy.xml' } else { $null }
            namedValues           = 'named-values.json'
            parametersTemplate    = 'parameters.template.json'
        }
        operationPolicies = ($operationPolicies.Keys | Sort-Object | ForEach-Object { "operations/$_.xml" })
    }

    # --- 9. Write ZIP ---
    Write-Step "Writing ZIP: $OutputFile"
    $zip = New-ExportZip -Path $OutputFile

    Add-ZipEntry -Zip $zip -EntryName 'manifest.json' -Content ($manifest | ConvertTo-Json -Depth 10)
    Add-ZipEntry -Zip $zip -EntryName 'definition.json' -Content $definitionJson
    Add-ZipEntry -Zip $zip -EntryName 'named-values.json' -Content ($namedValuesExport | ConvertTo-Json -Depth 5)
    Add-ZipEntry -Zip $zip -EntryName 'parameters.template.json' -Content ($paramsTemplate | ConvertTo-Json -Depth 5)

    if ($apiPolicyXml) {
        Add-ZipEntry -Zip $zip -EntryName 'api-policy.xml' -Content $apiPolicyXml
    }

    foreach ($safeName in $operationPolicies.Keys) {
        Add-ZipEntry -Zip $zip -EntryName "operations/$safeName.xml" -Content $operationPolicies[$safeName].xml
    }

    $zip.Dispose()

    Write-Step "Export complete: $OutputFile" -Level Success
    Write-Step ""
    Write-Step "Next steps:"
    Write-Step "  1. Copy parameters.template.json -> parameters.prod.json"
    Write-Step "  2. Fill in target environment values (backendUrl, named value secrets)"
    Write-Step "  3. Run: .\apim-tool.ps1 import -ZipFile $OutputFile -ParametersFile parameters.prod.json ..."
}

# ---------------------------------------------------------------------------
# IMPORT
# ---------------------------------------------------------------------------
function Import-Api {
    param(
        [string]$Token,
        [string]$BaseUri,
        [string]$ZipFile,
        [string]$ParametersFile
    )

    $headers = @{ Authorization = "Bearer $Token"; 'If-Match' = '*' }

    # --- 1. Read ZIP ---
    Write-Step "Opening ZIP: $ZipFile"
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipFile)

    $manifestJson = Read-ZipEntry -Zip $zip -EntryName 'manifest.json'
    if (-not $manifestJson) { throw "ZIP is missing manifest.json" }
    $manifest = $manifestJson | ConvertFrom-Json

    $definitionJson = Read-ZipEntry -Zip $zip -EntryName 'definition.json'
    if (-not $definitionJson) { throw "ZIP is missing definition.json" }

    $namedValuesJson = Read-ZipEntry -Zip $zip -EntryName 'named-values.json'
    $namedValues = if ($namedValuesJson) { $namedValuesJson | ConvertFrom-Json } else { @() }

    $templateJson = Read-ZipEntry -Zip $zip -EntryName 'parameters.template.json'

    # --- 2. Load parameters ---
    if (-not (Test-Path $ParametersFile)) {
        throw "Parameters file not found: $ParametersFile"
    }
    $paramsRaw = Get-Content -Path $ParametersFile -Raw | ConvertFrom-Json
    # Convert to hashtable for easy lookup
    $params = @{}
    $paramsRaw.PSObject.Properties | ForEach-Object { $params[$_.Name] = $_.Value }

    # Build named values hashtable
    $nvParams = @{}
    if ($paramsRaw.namedValues) {
        $paramsRaw.namedValues.PSObject.Properties | ForEach-Object { $nvParams[$_.Name] = $_.Value }
    }

    # Validate backendUrl
    if (-not $params.ContainsKey('backendUrl') -or -not $params['backendUrl'] -or $params['backendUrl'] -match 'FILL_ME_IN') {
        throw "parameters file must contain a valid 'backendUrl' value (not FILL_ME_IN)."
    }

    # Build flat rehydration table (backendUrl + any other top-level string keys)
    $rehydrationMap = @{}
    foreach ($key in $params.Keys) {
        if ($params[$key] -is [string] -and $key -ne '_comment' -and $key -ne 'namedValues') {
            $rehydrationMap[$key] = $params[$key]
        }
    }

    $apiId = $manifest.source.apiId

    Write-Step "Importing API: $($manifest.api.displayName) -> $apiId"
    Write-Step "  Backend URL: $($params['backendUrl'])"

    # --- 3. PUT API with OpenAPI spec ---
    Write-Step "Creating/updating API..."
    $definition = $definitionJson | ConvertFrom-Json
    $putApiBody = [ordered]@{
        properties = [ordered]@{
            format     = 'openapi+json'
            value      = $definitionJson
            path       = $manifest.api.path
            protocols  = $manifest.api.protocols
            serviceUrl = $params['backendUrl']
        }
    }
    $putApiUri = "$BaseUri/apis/$($apiId)?api-version=$API_VERSION"
    $putResp = Invoke-ApimApi -Method PUT -Uri $putApiUri -Headers $headers -Body $putApiBody -RawResponse
    $putRespObj = Invoke-ApimApi -Method PUT -Uri $putApiUri -Headers $headers -Body $putApiBody
    # Handle async
    if ($putResp -and $putResp.StatusCode -eq 202) {
        $asyncUrl = $putResp.Headers['Azure-AsyncOperation']
        if (-not $asyncUrl) { $asyncUrl = $putResp.Headers['Location'] }
        if ($asyncUrl) { Wait-ForAsyncOperation -AsyncUrl $asyncUrl -Headers $headers }
    }
    Write-Step "  API created/updated" -Level Success

    # --- 4. PUT API-level policy ---
    $apiPolicyXml = Read-ZipEntry -Zip $zip -EntryName 'api-policy.xml'
    if ($apiPolicyXml) {
        Write-Step "Applying API-level policy..."
        $rehydratedPolicy = Invoke-PolicyRehydration -PolicyXml $apiPolicyXml -Params $rehydrationMap
        $policyBody = [ordered]@{
            properties = [ordered]@{
                format = 'rawxml'
                value  = $rehydratedPolicy
            }
        }
        $policyUri = "$BaseUri/apis/$($apiId)/policies/policy?api-version=$API_VERSION"
        $policyResp = Invoke-ApimApi -Method PUT -Uri $policyUri -Headers $headers -Body $policyBody -RawResponse
        if ($policyResp -and $policyResp.StatusCode -eq 202) {
            $asyncUrl = $policyResp.Headers['Azure-AsyncOperation']
            if (-not $asyncUrl) { $asyncUrl = $policyResp.Headers['Location'] }
            if ($asyncUrl) { Wait-ForAsyncOperation -AsyncUrl $asyncUrl -Headers $headers }
        }
        Write-Step "  API policy applied" -Level Success
    } else {
        Write-Step "  No API-level policy in ZIP — skipping"
    }

    # --- 5. Per-operation policies ---
    $opEntries = Get-ZipEntries -Zip $zip -Prefix 'operations/'
    $opPolicyCount = 0
    foreach ($entryName in $opEntries) {
        if ($entryName -notmatch '\.xml$') { continue }
        # Derive operationId from filename (strip operations/ prefix and .xml suffix)
        $filename = [System.IO.Path]::GetFileNameWithoutExtension($entryName.Replace('operations/', ''))

        Write-Step "Applying policy for operation: $filename"
        $opXml = Read-ZipEntry -Zip $zip -EntryName $entryName
        if (-not $opXml) { continue }

        $rehydratedOpXml = Invoke-PolicyRehydration -PolicyXml $opXml -Params $rehydrationMap
        $opPolicyBody = [ordered]@{
            properties = [ordered]@{
                format = 'rawxml'
                value  = $rehydratedOpXml
            }
        }

        # Look up actual operation ID — filename is sanitized so we need to find by matching
        # First try direct match, then search operations list
        $opPolicyUri = "$BaseUri/apis/$($apiId)/operations/$filename/policies/policy?api-version=$API_VERSION"
        try {
            $opPolicyResp = Invoke-ApimApi -Method PUT -Uri $opPolicyUri -Headers $headers -Body $opPolicyBody -RawResponse
            if ($opPolicyResp -and $opPolicyResp.StatusCode -eq 202) {
                $asyncUrl = $opPolicyResp.Headers['Azure-AsyncOperation']
                if (-not $asyncUrl) { $asyncUrl = $opPolicyResp.Headers['Location'] }
                if ($asyncUrl) { Wait-ForAsyncOperation -AsyncUrl $asyncUrl -Headers $headers }
            }
            $opPolicyCount++
            Write-Step "  Applied: $filename" -Level Success
        } catch {
            Write-Step "  Could not apply policy for '$filename': $_" -Level Warn
        }
    }

    # --- 6. Named values ---
    $nvApplied = 0
    $nvSkipped = 0
    if ($namedValues.Count -gt 0) {
        Write-Step "Upserting named values..."
        foreach ($nv in $namedValues) {
            $nvDisplayName = $nv.displayName
            $nvValue = $nvParams[$nvDisplayName]

            if (-not $nvValue -or $nvValue -match 'FILL_ME_IN') {
                Write-Step "  Skipping '$nvDisplayName' (FILL_ME_IN — set value in parameters file)" -Level Warn
                $nvSkipped++
                continue
            }

            $nvBody = [ordered]@{
                properties = [ordered]@{
                    displayName = $nvDisplayName
                    value       = $nvValue
                    secret      = [bool]$nv.secret
                    tags        = $nv.tags
                }
            }
            $nvUri = "$BaseUri/namedValues/$($nv.name)?api-version=$API_VERSION"
            try {
                Invoke-ApimApi -Method PUT -Uri $nvUri -Headers $headers -Body $nvBody | Out-Null
                Write-Step "  Named value upserted: $nvDisplayName" -Level Success
                $nvApplied++
            } catch {
                Write-Step "  Failed to upsert named value '$nvDisplayName': $_" -Level Warn
            }
        }
    }

    $zip.Dispose()

    Write-Step ""
    Write-Step "Import complete!" -Level Success
    Write-Step "  API policies applied : $opPolicyCount operation(s)"
    Write-Step "  Named values applied : $nvApplied"
    Write-Step "  Named values skipped : $nvSkipped (FILL_ME_IN)"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
function Assert-Param {
    param([string]$Value, [string]$Name)
    if (-not $Value) { throw "-$Name is required for $Mode mode." }
}

Write-Step "APIM Tool — mode: $Mode"

# ── Auto-detect APIM instance if not fully specified ──────────────────────────
if (-not $SubscriptionId -or -not $ResourceGroup -or -not $ServiceName) {
    Write-Step "Auto-detecting APIM instance from current Azure login..."

    $azCtx = Get-AzContext
    if (-not $azCtx) {
        throw "Not logged in to Azure. Run 'Connect-AzAccount' first, or supply -SubscriptionId, -ResourceGroup, -ServiceName."
    }
    Write-Step "Subscription: $($azCtx.Subscription.Name)"

    $instances = Get-AzApiManagement
    if (-not $instances) {
        throw "No APIM instances found in subscription '$($azCtx.Subscription.Name)'. Supply -ResourceGroup and -ServiceName explicitly."
    }

    $apim = $null
    if ($instances.Count -eq 1) {
        $apim = $instances[0]
        Write-Step "Using APIM: $($apim.Name)  ($($apim.ResourceGroupName))"
    } else {
        Write-Host ""
        Write-Host "Multiple APIM instances found:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $instances.Count; $i++) {
            Write-Host "  [$i] $($instances[$i].Name)  ($($instances[$i].ResourceGroupName))"
        }
        $choice = Read-Host "Enter number"
        $apim = $instances[[int]$choice]
        Write-Step "Using APIM: $($apim.Name)  ($($apim.ResourceGroupName))"
    }

    if (-not $SubscriptionId) { $SubscriptionId = $azCtx.Subscription.Id }
    if (-not $ResourceGroup)  { $ResourceGroup  = $apim.ResourceGroupName }
    if (-not $ServiceName)    { $ServiceName    = $apim.Name }
}

$token = Get-BearerToken -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId

switch ($Mode) {
    'export' {
        Assert-Param -Value $ApiId      -Name ApiId
        Assert-Param -Value $OutputFile -Name OutputFile

        $baseUri = Build-ApimBaseUri -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ServiceName $ServiceName
        Export-Api -Token $token -BaseUri $baseUri -ApiId $ApiId -OutputFile $OutputFile
    }
    'import' {
        Assert-Param -Value $ZipFile        -Name ZipFile
        Assert-Param -Value $ParametersFile -Name ParametersFile

        if (-not (Test-Path $ZipFile)) { throw "ZIP file not found: $ZipFile" }

        $baseUri = Build-ApimBaseUri -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ServiceName $ServiceName
        Import-Api -Token $token -BaseUri $baseUri -ZipFile $ZipFile -ParametersFile $ParametersFile
    }
}
