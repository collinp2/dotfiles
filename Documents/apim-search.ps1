<#
.SYNOPSIS
    Search all Azure APIM policies and settings for a specific term.

.DESCRIPTION
    Auto-detects the APIM instance from your current Azure login. If multiple
    instances exist in the subscription, you will be prompted to choose one.
    Scans every policy level — global, product, API, and operation — plus
    operation URL templates. Outputs level, name, line number, and snippet
    for every match.

.PARAMETER SearchTerm
    The string to search for. Treated as a literal string (not regex).

.PARAMETER CaseSensitive
    By default the search is case-insensitive. Use this switch to make it exact.

.EXAMPLE
    ./apim-search.ps1 -SearchTerm "rewrite-uri"

.EXAMPLE
    ./apim-search.ps1 -SearchTerm "api.example.com" -CaseSensitive
#>

param(
    [Parameter(Mandatory, HelpMessage = "String to search for")]
    [string]$SearchTerm,

    [switch]$CaseSensitive
)

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

$ctx = New-AzApiManagementContext -ResourceGroupName $apim.ResourceGroupName -ServiceName $apim.Name

# ── Setup ─────────────────────────────────────────────────────────────────────

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$rxOptions = if ($CaseSensitive) {
    [System.Text.RegularExpressions.RegexOptions]::None
} else {
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
}
$escaped = [regex]::Escape($SearchTerm)

# ── Helper ────────────────────────────────────────────────────────────────────

function Find-InPolicy {
    param([string]$Xml, [string]$Level, [string]$Name)
    if (-not $Xml) { return }
    $lines = $Xml -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ([regex]::IsMatch($lines[$i], $escaped, $rxOptions)) {
            $script:results.Add([PSCustomObject]@{
                Level   = $Level
                Name    = $Name
                Line    = $i + 1
                Snippet = $lines[$i].Trim()
            })
        }
    }
}

# ── Search ────────────────────────────────────────────────────────────────────

# Global policy
Write-Host "Checking global policy..." -ForegroundColor Cyan
try { Find-InPolicy (Get-AzApiManagementPolicy -Context $ctx) "Global" "Global" }
catch { Write-Warning "Could not read global policy: $_" }

# Product policies
Write-Host "Checking product policies..." -ForegroundColor Cyan
Get-AzApiManagementProduct -Context $ctx | ForEach-Object {
    try { Find-InPolicy (Get-AzApiManagementPolicy -Context $ctx -ProductId $_.ProductId) "Product" $_.Title }
    catch {}
}

# APIs + operations
Write-Host "Checking API and operation policies..." -ForegroundColor Cyan
Get-AzApiManagementApi -Context $ctx | ForEach-Object {
    $api = $_
    Write-Host "  $($api.Name)" -ForegroundColor Gray

    # API-level policy
    try { Find-InPolicy (Get-AzApiManagementPolicy -Context $ctx -ApiId $api.ApiId) "API Policy" $api.Name }
    catch {}

    # Operations
    Get-AzApiManagementOperation -Context $ctx -ApiId $api.ApiId | ForEach-Object {
        $op = $_
        $label = "$($api.Name)  ›  $($op.Name)  [$($op.Method) $($op.UrlTemplate)]"

        # URL template
        if ([regex]::IsMatch($op.UrlTemplate, $escaped, $rxOptions)) {
            $script:results.Add([PSCustomObject]@{
                Level   = "Operation URL"
                Name    = "$($api.Name)  ›  $($op.Name)"
                Line    = "-"
                Snippet = "$($op.Method) $($op.UrlTemplate)"
            })
        }

        # Operation policy
        try { Find-InPolicy (Get-AzApiManagementPolicy -Context $ctx -ApiId $api.ApiId -OperationId $op.OperationId) "Operation Policy" $label }
        catch {}
    }
}

# ── Results ───────────────────────────────────────────────────────────────────

Write-Host ""
if ($results.Count -eq 0) {
    Write-Host "No matches found for '$SearchTerm'." -ForegroundColor Yellow
} else {
    Write-Host "Found $($results.Count) match(es) for '$SearchTerm':" -ForegroundColor Green
    Write-Host ""
    $results | Format-Table Level, Name, Line, Snippet -AutoSize -Wrap
}
