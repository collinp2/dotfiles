<#
.SYNOPSIS
    Search all Azure APIM policies and settings for a specific term.

.DESCRIPTION
    Auto-detects the APIM instance from your current Azure login. If multiple
    instances exist in the subscription, you will be prompted to choose one.

    Uses the APIM REST API directly so only policies explicitly defined at each
    level are searched — inherited/effective policies are not duplicated across
    every child operation.

    Strips Azure's default comment block before searching so boilerplate
    instructions don't generate false positives.

    Each policy that matches produces one result row showing how many lines
    matched and the first matching snippet.

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

$apimCtx = New-AzApiManagementContext -ResourceGroupName $apim.ResourceGroupName -ServiceName $apim.Name

# ── REST API helper ───────────────────────────────────────────────────────────
# Uses Invoke-AzRestMethod so a 404 means "no policy defined at this level"
# rather than returning an inherited/effective policy.

$subId    = $azCtx.Subscription.Id
$basePath = "/subscriptions/$subId/resourceGroups/$($apim.ResourceGroupName)" +
            "/providers/Microsoft.ApiManagement/service/$($apim.Name)"
$apiVer   = "api-version=2022-08-01"

function Get-PolicyXml([string]$ResourcePath) {
    $response = Invoke-AzRestMethod -Method GET `
        -Path "$basePath$ResourcePath/policies/policy?$apiVer&format=rawxml"
    if ($response.StatusCode -eq 200) {
        $xml = ($response.Content | ConvertFrom-Json).properties.value
        # Strip the Azure boilerplate comment block (<!-- ... -->) that appears
        # at the top of every policy — it contains common words that cause
        # false positives and is never user-authored content.
        $xml = [regex]::Replace($xml, '<!--.*?-->', '', `
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        return $xml
    }
    return $null  # 404 = no policy defined at this level
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

# APIs + operations (skip non-current revisions — Get-AzApiManagementApi returns
# every revision; ;rev= in the ApiId indicates a non-current revision copy)
Write-Host "Checking API and operation policies..." -ForegroundColor Cyan
Get-AzApiManagementApi -Context $apimCtx | Where-Object { $_.ApiId -notmatch ';rev=' } | ForEach-Object {
    $api = $_
    Write-Host "  $($api.Name)" -ForegroundColor Gray

    # API-level policy
    Find-InPolicy (Get-PolicyXml "/apis/$($api.ApiId)") "API Policy" $api.Name

    # Operations
    Get-AzApiManagementOperation -Context $apimCtx -ApiId $api.ApiId | ForEach-Object {
        $op = $_

        # URL template
        if ([regex]::IsMatch($op.UrlTemplate, $escaped, $rxOptions)) {
            $script:results.Add([PSCustomObject]@{
                Level   = "Operation URL"
                Name    = "$($api.Name)  ›  $($op.Name)"
                Matches = 1
                Line    = "-"
                Snippet = "$($op.Method) $($op.UrlTemplate)"
            })
        }

        # Operation policy (only if explicitly defined at this level)
        $label = "$($api.Name)  ›  $($op.Name)"
        Find-InPolicy (Get-PolicyXml "/apis/$($api.ApiId)/operations/$($op.OperationId)") "Operation Policy" $label
    }
}

# ── Results ───────────────────────────────────────────────────────────────────

Write-Host ""
if ($results.Count -eq 0) {
    Write-Host "No matches found for '$SearchTerm'." -ForegroundColor Yellow
} else {
    Write-Host "Found $($results.Count) match(es) for '$SearchTerm':" -ForegroundColor Green
    Write-Host ""
    $results | Format-Table Level, Name, Matches, Line, Snippet -AutoSize -Wrap
}
