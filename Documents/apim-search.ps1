<#
.SYNOPSIS
    Search all Azure APIM policies and settings for a specific term.

.DESCRIPTION
    Scans every policy level in an APIM instance — global, product, API, and
    operation — plus operation URL templates. Outputs matching line numbers
    and snippets so you can locate the term immediately.

.PARAMETER SearchTerm
    The string to search for. Treated as a literal string (not regex).

.PARAMETER ResourceGroup
    Azure resource group containing the APIM instance.

.PARAMETER ServiceName
    APIM service name.

.PARAMETER CaseSensitive
    By default the search is case-insensitive. Use this switch to make it exact.

.EXAMPLE
    ./apim-search.ps1 -SearchTerm "rewrite-uri" -ResourceGroup "myRG" -ServiceName "myAPIM"

.EXAMPLE
    ./apim-search.ps1 -SearchTerm "api.example.com" -ResourceGroup "myRG" -ServiceName "myAPIM" -CaseSensitive
#>

param(
    [Parameter(Mandatory, HelpMessage = "String to search for")]
    [string]$SearchTerm,

    [Parameter(Mandatory, HelpMessage = "Azure resource group name")]
    [string]$ResourceGroup,

    [Parameter(Mandatory, HelpMessage = "APIM service name")]
    [string]$ServiceName,

    [switch]$CaseSensitive
)

# ── Prerequisites ─────────────────────────────────────────────────────────────

if (-not (Get-Module -ListAvailable -Name Az.ApiManagement)) {
    Write-Error "Az.ApiManagement module not found. Run: Install-Module Az -Scope CurrentUser"
    exit 1
}

# ── Setup ─────────────────────────────────────────────────────────────────────

$ctx = New-AzApiManagementContext -ResourceGroupName $ResourceGroup -ServiceName $ServiceName
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
