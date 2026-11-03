using System.Diagnostics;
using System.Diagnostics.Tracing;
using System.Reflection;
using Azure.Core;
using Azure.Core.Diagnostics;
using Azure.Identity;
using Microsoft.Identity.Client;
using AzureManagedIdentityId = Azure.Identity.ManagedIdentityId;
using MsalManagedIdentityId = Microsoft.Identity.Client.AppConfig.ManagedIdentityId;

// Usage: MsalImdsRepro [resource]
// Env:   AZURE_CLIENT_ID          user-assigned identity client ID (omit for system-assigned)
//        TIMEOUT_SECONDS          how long to wait for each token request before cancelling (default 60)
//        MSAL_MI_DISABLE_IMDS_V2  set to "true" to make MSAL skip IMDSv2

var resource = args.Length > 0 ? args[0] : "https://management.azure.com/";
var clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID");
var timeout = TimeSpan.FromSeconds(int.TryParse(Environment.GetEnvironmentVariable("TIMEOUT_SECONDS"), out var t) ? t : 60);
var clock = Stopwatch.StartNew();

void Log(string message) => Console.WriteLine($"[{clock.ElapsedMilliseconds,6} ms] {message}");

string VersionOf(Assembly assembly) =>
    assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "?";

// Loaded by name: typeof(ManagedIdentityCredential) resolves to Azure.Core through the type forward.
Log($"Azure.Identity {VersionOf(Assembly.Load("Azure.Identity"))}, Azure.Core {VersionOf(typeof(TokenCredential).Assembly)}, " +
    $"MSAL {VersionOf(typeof(ManagedIdentityApplicationBuilder).Assembly)}, .NET {Environment.Version}");
Log($"resource={resource} client_id={(string.IsNullOrEmpty(clientId) ? "(system-assigned)" : clientId)} " +
    $"MSAL_MI_DISABLE_IMDS_V2={Environment.GetEnvironmentVariable("MSAL_MI_DISABLE_IMDS_V2") ?? "(unset)"} timeout={timeout.TotalSeconds}s");

// Raw requests: how the IMDS endpoint itself answers each path, independent of any SDK.
var clientIdQuery = string.IsNullOrEmpty(clientId) ? "" : $"&client_id={Uri.EscapeDataString(clientId)}";

await Probe("IMDSv2 platform metadata", $"http://169.254.169.254/metadata/identity/getplatformmetadata?cred-api-version=2.0{clientIdQuery}");
await Probe("IMDSv1 token", $"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource={Uri.EscapeDataString(resource)}{clientIdQuery}");

// The path SDK clients such as Microsoft.Data.SqlClient take.
var azureIdentityResult = await Acquire("Azure.Identity ManagedIdentityCredential", async ct =>
{
    using var listener = new AzureEventSourceListener(
        (e, message) => Log($"  {e.EventSource.Name} {e.Level}: {message}"), EventLevel.Verbose);

    var credential = new ManagedIdentityCredential(new ManagedIdentityCredentialOptions(
        string.IsNullOrEmpty(clientId) ? AzureManagedIdentityId.SystemAssigned : AzureManagedIdentityId.FromUserAssignedClientId(clientId)));

    var token = await credential.GetTokenAsync(new TokenRequestContext([resource + ".default"]), ct);
    return $"expires {token.ExpiresOn:O}";
});

// MSAL on its own, for comparison.
var msalResult = await Acquire("MSAL AcquireTokenForManagedIdentity", async ct =>
{
    var app = ManagedIdentityApplicationBuilder
        .Create(string.IsNullOrEmpty(clientId) ? MsalManagedIdentityId.SystemAssigned : MsalManagedIdentityId.WithUserAssignedClientId(clientId))
        .WithLogging((level, message, _) => Log($"  msal {level}: {message}"), Microsoft.Identity.Client.LogLevel.Verbose, enablePiiLogging: false)
        .Build();

    var result = await app.AcquireTokenForManagedIdentity(resource).ExecuteAsync(ct);
    return $"expires {result.ExpiresOn:O}";
});

Log($"SUMMARY: Azure.Identity {azureIdentityResult}; MSAL {msalResult}");
return azureIdentityResult == "ok" && msalResult == "ok" ? 0 : 1;

async Task<string> Acquire(string name, Func<CancellationToken, Task<string>> acquire)
{
    using var cts = new CancellationTokenSource(timeout);
    var start = clock.ElapsedMilliseconds;

    Log($"{name}: start");

    try
    {
        var detail = await acquire(cts.Token);
        Log($"{name}: token acquired in {clock.ElapsedMilliseconds - start} ms, {detail}");
        return "ok";
    }
    catch (OperationCanceledException)
    {
        Log($"{name}: CANCELLED after {clock.ElapsedMilliseconds - start} ms without a token");
        return "cancelled";
    }
    catch (Exception ex)
    {
        Log($"{name}: FAILED after {clock.ElapsedMilliseconds - start} ms: {ex.GetType().Name}: {ex.Message}");
        return "failed";
    }
}

async Task Probe(string name, string url)
{
    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
    using var request = new HttpRequestMessage(HttpMethod.Get, url);
    request.Headers.Add("Metadata", "true");

    var start = clock.ElapsedMilliseconds;

    try
    {
        using var response = await http.SendAsync(request);
        Log($"probe {name}: HTTP {(int)response.StatusCode} in {clock.ElapsedMilliseconds - start} ms");
    }
    catch (Exception ex)
    {
        Log($"probe {name}: {ex.GetType().Name} after {clock.ElapsedMilliseconds - start} ms: {ex.Message}");
    }
}
