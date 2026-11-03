**Repo:** AzureAD/microsoft-authentication-library-for-dotnet

**Title:** Managed identity token request hangs in Azure Container Instances (VNet) since IMDSv2-first probing; `MSAL_MI_DISABLE_IMDS_V2=true` fixes it

### Which version of MSAL.NET are you using?

4.91.1, via Azure.Core 1.60.0 / Azure.Identity 1.21.0 `ManagedIdentityCredential`. Works with Azure.Core 1.54.0 + MSAL 4.84.0.

### Platform

.NET 10, Linux container in Azure Container Instances, deployed into a VNet subnet, with a user-assigned managed identity selected by client ID.

### What is the problem?

`ManagedIdentityCredential.GetTokenAsync` doesn't return a token. It waits until the caller's cancellation token fires (30s in our case), so callers see `A task was canceled`. We first hit it through Microsoft.Data.SqlClient 7.1.1 with `Authentication=Active Directory Managed Identity`.

From the same container, IMDS answers both paths quickly:

| Request | Result |
|---|---|
| IMDSv1 `/metadata/identity/oauth2/token?api-version=2018-02-01` | 200, under a second |
| IMDSv2 `/metadata/identity/getplatformmetadata?cred-api-version=2.0` | 404, under a second |

Setting `MSAL_MI_DISABLE_IMDS_V2=true` makes the same token request succeed in under a second.

### Repro

A standalone repro (console app, Dockerfile, and an az CLI script that runs it in ACI with and without the switch, in a VNet and with a public IP) is attached / at <link>.

### Expected behavior

A 404 from the IMDSv2 platform metadata probe falls back to IMDSv1 promptly, as described in #6041.

### Logs

<paste the timeline and the verbose Azure-Identity / MSAL lines from logs-vnet-after.txt>
