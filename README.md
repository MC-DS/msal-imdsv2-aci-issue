# Managed identity token takes ~48s in Azure Container Instances since MSAL 4.84.2

In a Linux Azure Container Instance with a user-assigned managed identity,
`ManagedIdentityCredential.GetTokenAsync` takes about 48 seconds to return a token. Callers with a
shorter timeout see it cancelled; Microsoft.Data.SqlClient's default 15s or a 30s `Connect Timeout`
fail with `A task was canceled`. Setting `MSAL_MI_DISABLE_IMDS_V2=true` brings it back under a second.

## Cause

Before getting the token, MSAL's managed identity capability discovery sends two probes that ACI's IMDS
answers with 404. Each 404 is retried 5 times with exponential backoff by the Azure.Core pipeline that
`ManagedIdentityCredential` hands to MSAL:

| Step | Request | ACI answers | Time |
|---|---|---|---|
| IMDSv2 probe | `GET /metadata/identity/getplatformmetadata?cred-api-version=2.0&client_id=…` | 404 `404 page not found`, 5 attempts | ~24s |
| IMDSv1 probe | `GET /metadata/identity/oauth2/token?api-version=2018-02-01&client_id=…` | 400 (the expected probe answer) | ~0s |
| Binding strength | `GET /metadata/instance/compute?api-version=2021-02-01` | 404, 5 attempts | ~24s |
| Token | `GET /metadata/identity/oauth2/token?...&resource=…` | 200 | <1s |

The backoff between attempts was about 1.4s, 3.4s, 6.3s and 11.7s. Both probes report the 404 as "not
available" and discovery continues correctly; the time is all in retrying a 404 that's a definitive answer.

Calling `ManagedIdentityApplication` directly for a plain bearer token isn't affected. It logs
`Defaulting to IMDSv1 without probing` and gets a token in about 40ms.

## Results

All four cases ran in `australiaeast`, Linux, .NET 10.0.14, user-assigned identity selected by client ID.

| Case | Azure.Core / MSAL | Network | `MSAL_MI_DISABLE_IMDS_V2` | `ManagedIdentityCredential` | MSAL direct |
|---|---|---|---|---|---|
| `vnet-after` | 1.60.0 / 4.91.1 | VNet | unset | **48,088 ms** | 37 ms |
| `public-after` | 1.60.0 / 4.91.1 | public IP | unset | **47,617 ms** | 48 ms |
| `vnet-after-disabled` | 1.60.0 / 4.91.1 | VNet | `true` | 811 ms | 39 ms |
| `vnet-before` | 1.54.0 / 4.84.0 | VNet | unset | 651 ms | 43 ms |

Raw probes from the same containers: IMDSv2 platform metadata 404 in under 100ms, IMDSv1 token 200 in
under 500ms.

## Versions

| | Works | Slow |
|---|---|---|
| Azure.Identity | 1.21.0 | 1.21.0 |
| Azure.Core | 1.54.0 | 1.60.0 |
| Microsoft.Identity.Client | 4.84.0 | 4.91.1 |

Azure.Identity 1.21.0 forwards `ManagedIdentityCredential` to Azure.Core, which implements it on MSAL.
Azure.Core 1.60.0 requires MSAL 4.84.2 or later, the release where managed identity
[started probing IMDSv2 first](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/pull/6041).
The kill switch came later, in [4.89.0](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/pull/6178).

## What the repro does

`src/Program.cs` is a console app that, inside the container:

1. Sends the raw IMDSv2 probe and IMDSv1 token requests, and logs the status and timing of each.
2. Gets a token through `ManagedIdentityCredential`, the path SDK clients take, with Azure SDK
   event logs at Verbose.
3. Gets a token through `ManagedIdentityApplication` directly, with MSAL logs at Verbose.

Each token request is cancelled after `TIMEOUT_SECONDS` (default 60). The last line is a summary.

## Run it

Needs the az CLI signed in to a subscription where you can create a resource group. It creates a
resource group, a user-assigned identity, a Basic container registry, a VNet with a subnet delegated to
ACI, and four short-lived container groups (`restartPolicy: Never`). Works from bash or Git Bash on Windows.

```bash
./deploy.sh
```

Override `RG`, `LOCATION` or `TIMEOUT_SECONDS` through the environment. Each case's timeline is printed,
and full logs land in `logs-<case>.txt`. To see where the time goes, look for the Azure-Core
`attempt number` lines in `logs-vnet-after.txt`.

Clean up:

```bash
./deploy.sh cleanup
```

Run locally (off Azure, so both token requests fail quickly or time out; this only checks the build):

```bash
docker build -t repro:after .
docker build -t repro:before --build-arg AZURE_CORE_VERSION=1.54.0 --build-arg MSAL_VERSION=4.84.0 .
docker run --rm -e TIMEOUT_SECONDS=10 repro:after
```

## Workarounds

- Set `MSAL_MI_DISABLE_IMDS_V2=true` on the container. Only affects mTLS proof-of-possession, which plain
  bearer tokens don't use.
- Or raise the caller's timeout above ~50s, for example `Connect Timeout=60` for SqlClient. The first
  token in each process still takes ~48s.

## Not yet known

- Whether newer MSAL releases (4.92.0 and later) still retry. Build with `--build-arg MSAL_VERSION=<version>`.
