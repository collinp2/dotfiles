# apim-tool.ps1

A single-file PowerShell script to export and import Azure API Management APIs across environments. Packages an API's OpenAPI definition, policies, and named values into a ZIP file, then imports it into any target APIM instance.

Designed for **dev → test → prod** promotion workflows. No external modules required — runs on PowerShell 5.1 (Windows built-in).

---

## Prerequisites

- PowerShell 5.1 or later
- One of:
  - **Az PowerShell module** logged in via `Connect-AzAccount` _(recommended)_
  - **Azure CLI** (`az`) logged in via `az login`
  - A **service principal** with Contributor access to both source and target APIM instances

---

## Usage

### Export (auto-detect APIM from current login)

```powershell
.\apim-tool.ps1 export -ApiId "my-api" -OutputFile "my-api-export.zip"
```

If multiple APIM instances exist in the subscription, you will be prompted to choose one.

### Import (auto-detect target APIM)

```powershell
.\apim-tool.ps1 import -ZipFile "my-api-export.zip" -ParametersFile "parameters.prod.json"
```

### Explicit Target (skip auto-detection)

Supply all three location params to skip the auto-detect step entirely:

```powershell
# Export
.\apim-tool.ps1 export `
  -ApiId          "my-api" `
  -OutputFile     "my-api-export.zip" `
  -SubscriptionId "abc-123" `
  -ResourceGroup  "rg-dev" `
  -ServiceName    "my-apim-dev"

# Import
.\apim-tool.ps1 import `
  -ZipFile        "my-api-export.zip" `
  -ParametersFile "parameters.prod.json" `
  -SubscriptionId "abc-123" `
  -ResourceGroup  "rg-prod" `
  -ServiceName    "my-apim-prod"
```

### Service Principal Auth (optional)

If you're not using `Connect-AzAccount` or `az login`, pass credentials directly:

```powershell
.\apim-tool.ps1 export ... `
  -TenantId     "tenant-id" `
  -ClientId     "client-id" `
  -ClientSecret "client-secret"
```

---

## Parameters

| Parameter | Mode | Required | Description |
|---|---|---|---|
| `export` / `import` | both | yes | First positional argument — selects mode |
| `-ApiId` | export | yes | API identifier to export |
| `-OutputFile` | export | yes | Path for the output ZIP file |
| `-ZipFile` | import | yes | Path to a previously exported ZIP |
| `-ParametersFile` | import | yes | Path to your filled-in parameters JSON |
| `-SubscriptionId` | both | no | Azure subscription ID (auto-detected from current login) |
| `-ResourceGroup` | both | no | Resource group of the APIM instance (auto-detected) |
| `-ServiceName` | both | no | APIM service name (auto-detected) |
| `-TenantId` | both | no | Azure AD tenant ID (service principal auth) |
| `-ClientId` | both | no | Service principal client ID |
| `-ClientSecret` | both | no | Service principal secret |

---

## ZIP Contents

```
my-api-export.zip
├── manifest.json              # Source metadata (apiId, path, protocols, etc.)
├── definition.json            # OpenAPI 3.0 spec
├── api-policy.xml             # API-level policy (omitted if none)
├── named-values.json          # Referenced named value names/metadata (no secret values)
├── parameters.template.json   # Starter parameters file — copy and fill in for each env
└── operations/
    ├── get-users.xml
    ├── post-users.xml
    └── ...                    # One file per operation that has a policy
```

---

## Typical Workflow

```
1. Log in to the source environment and export
   Connect-AzAccount   # or: az login
   .\apim-tool.ps1 export -ApiId my-api -OutputFile my-api.zip

2. Create a parameters file for the target environment
   Copy-Item parameters.template.json parameters.prod.json
   # Edit parameters.prod.json — fill in backendUrl and any named value secrets

3. Switch context to the target subscription (if different), then import
   Set-AzContext -Subscription "prod-subscription-id"
   .\apim-tool.ps1 import -ZipFile my-api.zip -ParametersFile parameters.prod.json
```

---

## Parameters File

The export generates a `parameters.template.json` inside the ZIP. Copy it out and fill it in:

```json
{
  "backendUrl": "https://api.prod.example.com",
  "namedValues": {
    "my-subscription-key": "FILL_ME_IN",
    "my-jwt-secret":       "FILL_ME_IN_SECRET"
  }
}
```

- **`backendUrl`** — the backend service URL for the target environment (required)
- **`namedValues`** — supply values for each named value used by the API's policies
  - Named values left as `FILL_ME_IN` are skipped with a warning (import continues)
  - Secret named values exported with `FILL_ME_IN_SECRET` must be supplied manually

---

## Policy Parameterization

On **export**, backend URLs in policies are automatically replaced with `{{backendUrl}}` tokens so the ZIP is environment-neutral:

```xml
<!-- Before export -->
<set-backend-service base-url="https://api.dev.example.com" />

<!-- In the ZIP -->
<set-backend-service base-url="{{backendUrl}}" />
```

On **import**, `{{backendUrl}}` (and any other top-level keys in your parameters file) are substituted back with the real values for the target environment.

Named value references (`{{my-named-value}}`) are left as-is — APIM resolves them at runtime.

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| API or operation has no policy | Skipped gracefully (no error) |
| Named value is a secret | Name and `secret: true` flag exported; value never included |
| API has >100 operations | `nextLink` pagination followed automatically |
| PUT returns HTTP 202 | Async operation polled up to 120 seconds |
| Running in Azure Cloud Shell | After export completes, prompted to press `1` to trigger a browser download of the ZIP |
| `FILL_ME_IN` value in parameters | Warning printed; that named value skipped; import continues |
| Not logged in | Clear error: _"Run Connect-AzAccount or az login, or supply -ClientId/-ClientSecret/-TenantId"_ |
| Multiple APIM instances | Numbered prompt — choose the target instance |

---

## Required RBAC

The identity running the script needs the following on both source and target APIM instances:

- `API Management Service Contributor` — or a custom role with read access to APIs, policies, named values (export) and write access (import)

---

## Azure REST API Version

All calls use `api-version=2022-08-01`.
