# apim-search.ps1

Search Azure API Management policies for a specific string. Scans global, product, API-level, operation-level policies, and policy fragments — and prints a results table showing where each match was found.

Designed for auditing and troubleshooting: find which APIs reference a backend URL, named value, header, or any other string across your entire APIM instance.

---

## Prerequisites

- PowerShell 5.1 or later
- **Az PowerShell module** logged in via `Connect-AzAccount`

---

## Usage

```powershell
# Search (case-insensitive by default)
.\apim-search.ps1 -SearchTerm "api.example.com"

# Case-sensitive search
.\apim-search.ps1 -SearchTerm "MyNamedValue" -CaseSensitive

# Omit -SearchTerm to be prompted
.\apim-search.ps1
```

> **Important:** Save the script as a `.ps1` file and run it from the terminal. Pasting the script body directly into the Cloud Shell terminal breaks the `param()` block.

If multiple APIM instances exist in the subscription, you will be prompted to choose one.

---

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-SearchTerm` | no | String to search for. Prompted interactively if omitted. |
| `-CaseSensitive` | no | Switch. By default the search is case-insensitive. |

---

## What Gets Searched

| Scope | Notes |
|---|---|
| Global policy | The tenant-wide inbound/outbound policy |
| Product policies | One per product in the APIM instance |
| API-level policies | One per API (current revision only) |
| Operation-level policies | One per operation per API |
| Policy fragments | All named reusable policy fragments |

---

## Output

Results are printed as a table:

```
Found 3 match(es) for 'api.example.com':

Level             Name                  Matches  Line  Snippet
-----             ----                  -------  ----  -------
API Policy        my-api                      1     4  <set-backend-service base-url="https://api.example.com" />
Operation Policy  my-api  ›  GET /users       1     7  <set-backend-service base-url="https://api.example.com" />
Policy Fragment   auth-header-fragment        1     2  <!-- sends to https://api.example.com -->
```

- **Level** — scope where the match was found
- **Name** — API name, product name, or fragment name
- **Matches** — total number of matching lines in that policy
- **Line** — line number of the first match
- **Snippet** — trimmed text of the first matching line

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| No matches found | Prints a yellow "No matches found" message |
| Azure boilerplate comment block | Stripped before searching — never produces false positives |
| Non-current API revisions | Skipped (`apiId` containing `;rev=` is excluded) |
| Operation-level policies | May return inherited/effective content in some environments, which can produce false positives — results should be verified manually |
| Multiple APIM instances | Numbered prompt — choose the target instance |
| Not logged in | Error: _"Not logged in to Azure. Run 'Connect-AzAccount' first."_ |

---

## Required RBAC

The identity running the script needs read access to the APIM instance:

- `API Management Service Reader` — or any role with read access to policies, products, and APIs
