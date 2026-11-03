FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG AZURE_CORE_VERSION=1.60.0
ARG MSAL_VERSION=4.91.1
WORKDIR /src
COPY src/ .
RUN dotnet publish -c Release -p:AzureCoreVersion=${AZURE_CORE_VERSION} -p:MsalVersion=${MSAL_VERSION} -o /app

FROM mcr.microsoft.com/dotnet/runtime:10.0
WORKDIR /app
COPY --from=build /app .
USER app
ENTRYPOINT ["dotnet", "MsalImdsRepro.dll"]
