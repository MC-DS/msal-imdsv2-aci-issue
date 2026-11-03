**Repo:** Azure/azure-sdk-for-net (Azure.Core / Azure.Identity), cross-referenced on AzureAD/microsoft-authentication-library-for-dotnet

**Title:** ManagedIdentityCredential takes ~48s in Azure Container Instances: 404s from MSAL capability-discovery probes are retried 5 times

### Library name and version

Azure.Identity 1.21.0 → Azure.Core 1.60.0, Microsoft.Identity.Client 4.91.1. Not affected: Azure.Core 1.54.0 + MSAL 4.84.0.

### Describe the bug

In a Linux Azure Container Instance with a user-assigned managed identity, the first `ManagedIdentityCredential.GetTokenAsync` takes about 48 seconds. MSAL's capability discovery sends two probes that ACI's IMDS answers with 404, and each is retried 5 times with exponential backoff by the Azure.Core pipeline:

| Request | ACI answers | Time |
|---|---|---|
| `GET /metadata/identity/getplatformmetadata?cred-api-version=2.0&client_id=…` | 404 `404 page not found`, 5 attempts | ~24s |
| `GET /metadata/identity/oauth2/token?api-version=2018-02-01&client_id=…` (v1 probe) | 400 | ~0s |
| `GET /metadata/instance/compute?api-version=2021-02-01` | 404, 5 attempts | ~24s |
| v1 token request | 200 | <1s |

Both 404s are definitive answers ("IMDSv2 not available", "no compute metadata on this host"), and MSAL treats them that way once the retries finish. Callers with a shorter timeout, such as Microsoft.Data.SqlClient with `Connect Timeout=30`, fail with `A task was canceled`.

Setting `MSAL_MI_DISABLE_IMDS_V2=true` skips the probes, and the token arrives in under a second. Calling `ManagedIdentityApplication` directly for a bearer token isn't affected (`Defaulting to IMDSv1 without probing`).

The VNet doesn't matter: a container group with a public IP behaves the same.

### Expected behavior

A 404 from the IMDSv2 platform-metadata probe and from `/metadata/instance/compute` during discovery isn't retried, so the first token takes about as long as it did with Azure.Core 1.54.0 (under a second).

### Results

| Azure.Core / MSAL | Network | `MSAL_MI_DISABLE_IMDS_V2` | `ManagedIdentityCredential` |
|---|---|---|---|
| 1.60.0 / 4.91.1 | VNet | unset | 48,088 ms |
| 1.60.0 / 4.91.1 | public IP | unset | 47,617 ms |
| 1.60.0 / 4.91.1 | VNet | `true` | 811 ms |
| 1.54.0 / 4.84.0 | VNet | unset | 651 ms |

### Reproduction steps

https://github.com/MC-DS/msal-imdsv2-aci-issue: a console app, a Dockerfile, and `deploy.sh`, which runs all four cases in ACI with the az CLI and saves the verbose logs.

### Log excerpt (first probe; the compute probe repeats the same pattern)

```
[   782 ms] Azure-Core Informational: Request [fc70c5e1-…] GET http://169.254.169.254/metadata/identity/getplatformmetadata?cred-api-version=REDACTED&client_id=REDACTED
[  1749 ms] Azure-Core Warning: Error response [fc70c5e1-…] 404 Not Found (00.0s)
[  3114 ms] Azure-Core Informational: Request [fc70c5e1-…] attempt number 2 took 00.0s
[  3117 ms] Azure-Core Warning: Error response [fc70c5e1-…] 404 Not Found (00.0s)
[  6558 ms] Azure-Core Informational: Request [fc70c5e1-…] attempt number 3 took 00.0s
[  6560 ms] Azure-Core Warning: Error response [fc70c5e1-…] 404 Not Found (00.0s)
[ 12876 ms] Azure-Core Informational: Request [fc70c5e1-…] attempt number 4 took 00.0s
[ 12879 ms] Azure-Core Warning: Error response [fc70c5e1-…] 404 Not Found (00.0s)
[ 24622 ms] Azure-Core Informational: Request [fc70c5e1-…] attempt number 5 took 00.0s
[ 24629 ms] Azure-Identity Informational: [HttpManager] Finished ExecuteAsync in 23869 ms
[ 24630 ms] Azure-Identity Informational: [Managed Identity] IMDSv2 managed identity is not available. Status code: NotFound, Body: 404 page not found
[ 24638 ms] Azure-Identity Informational: [Managed Identity] ImdsV1 detected.
[ 24642 ms] Azure-Core Informational: Request [646edea5-…] GET http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01
  … 404, retried 5 times …
[ 48195 ms] Azure-Identity Informational: [Managed Identity] IMDS compute metadata request failed. StatusCode: NotFound
[ 48201 ms] Azure-Identity Informational: Managed Identity source selected: Imds with ID: ClientId REDACTED
```

### Environment

Azure Container Instances, Linux, `australiaeast`, .NET 10.0.14, Ubuntu 24.04 base image, user-assigned managed identity.
