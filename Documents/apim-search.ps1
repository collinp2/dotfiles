<#
.SYNOPSIS
    Search Azure APIM global, product, and API-level policies for a specific term.

.DESCRIPTION
    Auto-detects the APIM instance from your current Azure login. If multiple
    instances exist in the subscription, you will be prompted to choose one.

    Searches: global policy, product policies, and API-level policies.
    Operation-level policy search is excluded — the APIM REST API returns
    effective/inherited content at the operation level regardless of format,
    making operation results unreliable.

.PARAMETER SearchTerm
    The string to search for. Treated as a literal string (not regex).

.PARAMETER CaseSensitive
    By default the search is case-insensitive. Use this switch to make it exact.

.EXAMPLE
    ./apim-search.ps1 -SearchTerm "admissions-decision-processing"

.EXAMPLE
    ./apim-search.ps1 -SearchTerm "api.example.com" -CaseSensitive
#>

param(
    [string]$SearchTerm,
    [switch]$CaseSensitive
)

# ── Prompt if not provided ────────────────────────────────────────────────────
if (-not $SearchTerm) {
    $SearchTerm = Read-Host "Search term"
}
if (-not $SearchTerm) {
    Write-Error "No search term provided."
    exit 1
}
Write-Host "Searching for: '$SearchTerm'" -ForegroundColor Magenta

# ── Verify Azure login ────────────────────────────────────────────────────────

$azCtx = Get-AzContext
if (-not $azCtx) {
    Write-Error "Not logged in to Azure. Run 'Connect-AzAccount' first."
    exit 1
}
Write-Host "Subscription: $($azCtx.Subscription.Name)" -ForegroundColor DarkGray

# ── Find APIM instance ────────────────────────────────────────────────────────

Write-Host "Discovering APIM instances..." -ForegroundColor Cyan
$instances = Get-AzApiManagement

if (-not $instances) {
    Write-Error "No APIM instances found in subscription '$($azCtx.Subscription.Name)'."
    exit 1
}

if ($instances.Count -eq 1) {
    $apim = $instances[0]
    Write-Host "Using: $($apim.Name)  ($($apim.ResourceGroupName))" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "Multiple APIM instances found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $instances.Count; $i++) {
        Write-Host "  [$i] $($instances[$i].Name)  ($($instances[$i].ResourceGroupName))"
    }
    $choice = Read-Host "Enter number"
    $apim = $instances[[int]$choice]
}

$apimCtx = New-AzApiManagementContext -ResourceGroupName $apim.ResourceGroupName -ServiceName $apim.Name

# ── REST API helper ───────────────────────────────────────────────────────────

$subId    = $azCtx.Subscription.Id
$basePath = "/subscriptions/$subId/resourceGroups/$($apim.ResourceGroupName)" +
            "/providers/Microsoft.ApiManagement/service/$($apim.Name)"
$apiVer   = "api-version=2022-08-01"

function Get-PolicyXml([string]$ResourcePath) {
    $response = Invoke-AzRestMethod -Method GET `
        -Path "$basePath$ResourcePath/policies/policy?$apiVer"
    if ($response.StatusCode -ne 200) { return $null }

    $xml = ($response.Content | ConvertFrom-Json).properties.value

    # Strip Azure's boilerplate comment block — never user-authored content.
    $xml = [regex]::Replace($xml, '<!--.*?-->', '', `
        [System.Text.RegularExpressions.RegexOptions]::Singleline)

    return $xml
}

# ── Setup ─────────────────────────────────────────────────────────────────────

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$rxOptions = if ($CaseSensitive) {
    [System.Text.RegularExpressions.RegexOptions]::None
} else {
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
}
$escaped = [regex]::Escape($SearchTerm)

function Find-InPolicy {
    param([string]$Xml, [string]$Level, [string]$Name)
    if (-not $Xml) { return }
    $lines        = $Xml -split "`n"
    $matchedLines = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ([regex]::IsMatch($lines[$i], $escaped, $rxOptions)) {
            $matchedLines += [PSCustomObject]@{ Line = $i + 1; Text = $lines[$i].Trim() }
        }
    }
    if ($matchedLines.Count -gt 0) {
        $script:results.Add([PSCustomObject]@{
            Level   = $Level
            Name    = $Name
            Matches = $matchedLines.Count
            Line    = $matchedLines[0].Line
            Snippet = $matchedLines[0].Text
        })
    }
}

# ── Search ────────────────────────────────────────────────────────────────────

# Global policy
Write-Host "Checking global policy..." -ForegroundColor Cyan
Find-InPolicy (Get-PolicyXml "") "Global" "Global"

# Product policies
Write-Host "Checking product policies..." -ForegroundColor Cyan
Get-AzApiManagementProduct -Context $apimCtx | ForEach-Object {
    Find-InPolicy (Get-PolicyXml "/products/$($_.ProductId)") "Product" $_.Title
}

# API-level policies (skip non-current revisions)
Write-Host "Checking API policies..." -ForegroundColor Cyan
$apis = Get-AzApiManagementApi -Context $apimCtx | Where-Object { $_.ApiId -notmatch ';rev=' }
$apiTotal = $apis.Count
$apiIndex = 0
$apis | ForEach-Object {
    $api = $_
    $apiIndex++
    Write-Progress -Activity "Scanning API policies" `
        -Status "$apiIndex of $apiTotal : $($api.Name)" `
        -PercentComplete (($apiIndex / $apiTotal) * 100)

    Find-InPolicy (Get-PolicyXml "/apis/$($api.ApiId)") "API Policy" $api.Name

    # Operations
    Get-AzApiManagementOperation -Context $apimCtx -ApiId $api.ApiId | ForEach-Object {
        $op    = $_
        $label = "$($api.Name)  ›  $($op.Name)"
        Find-InPolicy (Get-PolicyXml "/apis/$($api.ApiId)/operations/$($op.OperationId)") "Operation Policy" $label
    }
}

Write-Progress -Activity "Scanning API policies" -Completed

# ── Results ───────────────────────────────────────────────────────────────────

Write-Host ""
if ($results.Count -eq 0) {
    Write-Host "No matches found for '$SearchTerm'." -ForegroundColor Yellow
} else {
    Write-Host "Found $($results.Count) match(es) for '$SearchTerm':" -ForegroundColor Green
    Write-Host ""
    $results | Format-Table Level, Name, Matches, Line, Snippet -AutoSize -Wrap
}
