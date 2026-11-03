# Managed identity token hangs in Azure Container Instances after MSAL 4.84.2

In a Linux Azure Container Instance deployed into a VNet, with a user-assigned managed identity,
`ManagedIdentityCredential.GetTokenAsync` never returns a token. It runs until the caller's
cancellation token fires. Setting `MSAL_MI_DISABLE_IMDS_V2=true` makes it succeed in under a second.

The IMDS endpoint itself is healthy. From the same container:

| Request | Result |
|---|---|
| `GET /metadata/identity/oauth2/token?api-version=2018-02-01&...` (IMDSv1) | 200, under a second |
| `GET /metadata/identity/getplatformmetadata?cred-api-version=2.0&...` (IMDSv2 probe) | 404, under a second |
| `ManagedIdentityCredential.GetTokenAsync`, Azure.Core 1.60.0 + MSAL 4.91.1 | no token, cancelled at the caller's timeout (30s) |
| Same, with `MSAL_MI_DISABLE_IMDS_V2=true` | token, under a second |

## Versions

| | Works | Fails |
|---|---|---|
| Azure.Identity | 1.21.0 | 1.21.0 |
| Azure.Core | 1.54.0 | 1.60.0 |
| Microsoft.Identity.Client | 4.84.0 | 4.91.1 |

Azure.Identity 1.21.0 forwards `ManagedIdentityCredential` to Azure.Core, which implements it on MSAL.
Azure.Core 1.60.0 requires MSAL 4.84.2 or later, the release where managed identity
[started probing IMDSv2 first](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/pull/6041).
The kill switch came later, in [4.89.0](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/pull/6178).

The first seen symptom was Microsoft.Data.SqlClient 7.1.1 with
`Authentication=Active Directory Managed Identity` (and `Active Directory Default`) failing with
`Failed to acquire access token for ActiveDirectoryManagedIdentity: Unexpected error: A task was canceled.`
SqlClient isn't needed to reproduce it.

## What the repro does

`src/Program.cs` is a console app that, inside the container:

1. Sends the raw IMDSv2 probe and IMDSv1 token requests, and logs the status and timing of each.
2. Gets a token through `ManagedIdentityCredential`, the path SDK clients take, with Azure SDK
   event logs at Verbose.
3. Gets a token through `ManagedIdentityApplication` directly, with MSAL logs at Verbose.

Each token request is cancelled after `TIMEOUT_SECONDS` (default 60). The last line is a summary.

Calling MSAL directly for a plain bearer token logs `Defaulting to IMDSv1 without probing`. The IMDSv2
path seems to be reached only through `ManagedIdentityCredential`, so step 2 is the one that matters.

## Run it

Needs the az CLI signed in to a subscription where you can create a resource group. It creates a
resource group, a user-assigned identity, a Basic container registry, a VNet with a subnet delegated to
ACI, and four short-lived container groups (`restartPolicy: Never`).

```bash
./deploy.sh
```

Override `RG`, `LOCATION` or `TIMEOUT_SECONDS` through the environment. Each case's timeline is printed,
and full logs land in `logs-<case>.txt`.

| Case | Image | Network | `MSAL_MI_DISABLE_IMDS_V2` | Expected if the bug reproduces |
|---|---|---|---|---|
| `vnet-after` | after | VNet | unset | `ManagedIdentityCredential` cancelled |
| `vnet-after-disabled` | after | VNet | `true` | token |
| `vnet-before` | before | VNet | unset | token |
| `public-after` | after | public IP | unset | shows whether the VNet matters |

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

## Not yet known

- Where inside the IMDSv2 path the request stalls. The verbose logs from `vnet-after` should show it.
- Whether the VNet is required. `public-after` answers that.
- Whether newer MSAL releases (4.92.0 and later) still fail. Build with `--build-arg MSAL_VERSION=<version>`.
