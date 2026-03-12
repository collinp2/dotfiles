# apim-tool.ps1

A single-file PowerShell script to export and import Azure API Management APIs across environments. Packages an API's OpenAPI definition, policies, and named values into a ZIP file, then imports it into any target APIM instance.

Designed for **dev → test → prod** promotion workflows. No external modules required — runs on PowerShell 5.1 (Windows built-in).

---

## Prerequisites

- PowerShell 5.1 or later
- One of:
  - **Azure CLI** (`az`) logged in via `az login` _(recommended)_
  - A **service principal** with Contributor access to both source and target APIM instances

---

## Usage

### Export

```powershell
.\apim-tool.ps1 export `
  -SubscriptionId "abc-123" `
  -ResourceGroup  "rg-dev" `
  -ServiceName    "my-apim-dev" `
  -ApiId          "my-api" `
  -OutputFile     "my-api-export.zip"
```

### Import

```powershell
.\apim-tool.ps1 import `
  -ZipFile        "my-api-export.zip" `
  -ParametersFile "parameters.prod.json" `
  -SubscriptionId "abc-123" `
  -ResourceGroup  "rg-prod" `
  -ServiceName    "my-apim-prod"
```

### Service Principal Auth (optional)

If you're not using `az login`, pass credentials directly:

```powershell
.\apim-tool.ps1 export ... `
  -TenantId     "tenant-id" `
  -ClientId     "client-id" `
  -ClientSecret "client-secret"
```

---

## Parameters

| Parameter | Mode | Description |
|---|---|---|
| `export` / `import` | both | First positional argument — selects mode |
| `-SubscriptionId` | both | Azure subscription ID |
| `-ResourceGroup` | both | Resource group of the APIM instance |
| `-ServiceName` | both | APIM service name |
| `-ApiId` | export | API identifier to export |
| `-OutputFile` | export | Path for the output ZIP file |
| `-ZipFile` | import | Path to a previously exported ZIP |
| `-ParametersFile` | import | Path to your filled-in parameters JSON |
| `-TenantId` | both | Azure AD tenant ID (service principal auth) |
| `-ClientId` | both | Service principal client ID |
| `-ClientSecret` | both | Service principal secret |

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
1. Export from dev
   .\apim-tool.ps1 export -ApiId my-api -OutputFile my-api.zip ...

2. Create a parameters file for the target environment
   Copy-Item parameters.template.json parameters.prod.json
   # Edit parameters.prod.json — fill in backendUrl and any named value secrets

3. Import to prod
   .\apim-tool.ps1 import -ZipFile my-api.zip -ParametersFile parameters.prod.json ...
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
| `FILL_ME_IN` value in parameters | Warning printed; that named value skipped; import continues |
| `az` not logged in | Clear error: _"run az login or supply -ClientId/-ClientSecret/-TenantId"_ |

---

## Required RBAC

The identity running the script needs the following on both source and target APIM instances:

- `API Management Service Contributor` — or a custom role with read access to APIs, policies, named values (export) and write access (import)

---

## Azure REST API Version

All calls use `api-version=2022-08-01`.
