#!/bin/bash
#
# executable
#

set -e
# Read variables in configuration file
parent_path=$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../"
    pwd -P
)
SCRIPTS_DIRECTORY=`dirname $0`
source "$SCRIPTS_DIRECTORY"/common.sh

# container version (current date)
export APP_VERSION=$(date +"%y%m%d.%H%M%S")
# container internal HTTP port
export APP_PORT=5000
# webapp prefix 
export AZURE_APP_PREFIX="testcalp"

env_path=$1
if [[ -z $env_path ]]; then
    env_path="$(dirname "${BASH_SOURCE[0]}")/../configuration/.default.env"
fi

printMessage "Starting test with local Docker service using the configuration in this file ${env_path}"

if [[ $env_path ]]; then
    if [ ! -f "$env_path" ]; then
        printError "$env_path does not exist."
        exit 1
    fi
    set -o allexport
    source "$env_path"
    set +o allexport
else
    printWarning "No env. file specified. Using environment variables."
fi


function deployAzureInfrastructure(){
    subscription=$1
    region=$2
    prefix=$3
    sku=$4
    datadep=$(date +"%y%M%d-%H%M%S")
    resourcegroup="${prefix}rg"
    webapp="${prefix}webapp"

    cmd="az group create  --subscription $subscription --location $region --name $resourcegroup --output none "
    printProgress "$cmd"
    eval "$cmd"

    checkError
    cmd="az deployment group create \
        --name $datadep \
        --resource-group $resourcegroup \
        --subscription $subscription \
        --template-file $SCRIPTS_DIRECTORY/arm-template.system-assigned.json \
        --output none \
        --parameters \
        webAppName=$webapp sku=$sku"
    printProgress "$cmd"
    eval "$cmd"
    checkError
    
    # get ACR login server dns name
    ACR_LOGIN_SERVER=$(az deployment group show --resource-group $resourcegroup -n $datadep | jq -r '.properties.outputs.acrLoginServer.value')
    # get WebApp Url
    WEB_APP_SERVER=$(az deployment group show --resource-group $resourcegroup -n $datadep | jq -r '.properties.outputs.webAppServer.value')
    # get ACR Name
    ACR_NAME=$(az deployment group show --resource-group $resourcegroup -n $datadep | jq -r '.properties.outputs.acrName.value')
    # get WebApp Tenant ID
    WEB_APP_TENANT_ID=$(az deployment group show --resource-group $resourcegroup -n $datadep | jq -r '.properties.outputs.webAppTenantId.value')
    # get WebApp Object ID
    WEB_APP_OBJECT_ID=$(az deployment group show --resource-group $resourcegroup -n $datadep | jq -r '.properties.outputs.webAppObjectId.value')

}

function undeployAzureInfrastructure(){
    subscription=$1
    prefix=$2
    resourcegroup="${prefix}rg"

    cmd="az group delete  --subscription $subscription  --name $resourcegroup -y --output none "
    printProgress "$cmd"
    eval "$cmd"
}

function buildWebAppContainer() {
    ContainerRegistryName="$1"
    apiModule="$2"
    imageName="$3"
    imageTag="$4"
    imageLatestTag="$5"
    portHttp="$6"

    targetDirectory="$(dirname "${BASH_SOURCE[0]}")/../$apiModule"

    if [ ! -d "$targetDirectory" ]; then
            echo "Directory '$targetDirectory' does not exist."
            exit 1
    fi

    echo "Building and uploading the docker image for '$apiModule'"

    # Navigate to API module folder
    pushd "$targetDirectory" > /dev/null

    # Build the image
    echo "Building the docker image for '$imageName:$imageTag'"
    cmd="az acr build --registry $ContainerRegistryName --image ${imageName}:${imageTag} --image ${imageName}:${imageLatestTag} -f Dockerfile --build-arg APP_VERSION=${imageTag} --build-arg ARG_PORT_HTTP=${portHttp} . --output none"
    printProgress "$cmd"
    eval "$cmd"

    
    popd > /dev/null

}

function deployWebAppContainer(){
    SUBSCRIPTION_ID="$1"
    prefix="$2"
    ContainerRegistryUrl="$3"
    ContainerRegistryName="$4"
    imageName="$5"
    imageTag="$6"
    appVersion="$7"
    portHTTP="$8"

    resourcegroup="${prefix}rg"
    webapp="${prefix}webapp"

    # When deployed, WebApps get automatically a managed identity. Ensuring this MSI has AcrPull rights
    printProgress  "Ensure ${webapp} has AcrPull role assignment on ${ContainerRegistryName}..."
    WebAppMsiPrincipalId=$(az webapp show -n "$webapp" -g "$resourcegroup" -o json | jq -r .identity.principalId)
    WebAppMsiAcrPullAssignmentCount=$(az role assignment list --assignee "$WebAppMsiPrincipalId" --scope /subscriptions/"${SUBSCRIPTION_ID}"/resourceGroups/"${resourcegroup}"/providers/Microsoft.ContainerRegistry/registries/"${ContainerRegistryName}" | jq -r 'select(.[].roleDefinitionName=="AcrPull") | length')

    if [ "$WebAppMsiAcrPullAssignmentCount" != "1" ];
    then
        printProgress  "Assigning AcrPull role assignment on scope ${ContainerRegistryName}..."
        az role assignment create --assignee-object-id "$WebAppMsiPrincipalId" --assignee-principal-type ServicePrincipal --scope /subscriptions/"${SUBSCRIPTION_ID}"/resourceGroups/"${resourcegroup}"/providers/Microsoft.ContainerRegistry/registries/"${ContainerRegistryName}" --role "AcrPull"
    fi

    printProgress  "Check if WebApp ${webapp} use Managed Identity for the access to ACR ${ContainerRegistryName}..."
    WebAppAcrConfigAcrEnabled=$(az resource show --ids /subscriptions/"${SUBSCRIPTION_ID}"/resourceGroups/"${resourcegroup}"/providers/Microsoft.Web/sites/"${webapp}"/config/web | jq -r ".properties.acrUseManagedIdentityCreds")
    if [ "$WebAppAcrConfigAcrEnabled" = false ];
    then
        printProgress "Enabling Acr on ${webapp}..."
        az resource update --ids /subscriptions/"${SUBSCRIPTION_ID}"/resourceGroups/"${resourcegroup}"/providers/Microsoft.Web/sites/"${webapp}"/config/web --set properties.acrUseManagedIdentityCreds=True
    fi


    printProgress "Create Containers"
    FX_Version="Docker|$ContainerRegistryUrl/$imageName:$imageTag"

    #Configure the ACR, Image and Tag to pull
    cmd="az resource update --ids /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${resourcegroup}/providers/Microsoft.Web/sites/${webapp}/config/web --set properties.linuxFxVersion=\"$FX_Version\" -o none --force-string"
    printProgress "$cmd"
    eval "$cmd"

    printProgress "Create Config"
    cmd="az webapp config appsettings set -g "$resourcegroup" -n "$webapp" \
    --settings APP_VERSION=${appVersion} PORT_HTTP=${portHTTP} --output none"
    printProgress "$cmd"
    eval "$cmd"
}

# Check Azure connection
printMessage "Check Azure connection for subscription: '$AZURE_SUBSCRIPTION_ID'"
azLogin
checkError

# Deploy infrastructure image
printMessage "Deploy infrastructure subscription: '$AZURE_SUBSCRIPTION_ID' region: '$AZURE_REGION' prefix: '$AZURE_APP_PREFIX' sku: 'B2'"
deployAzureInfrastructure $AZURE_SUBSCRIPTION_ID $AZURE_REGION $AZURE_APP_PREFIX "B2"
printMessage "Azure Container Registry DNS name: ${ACR_LOGIN_SERVER}"
printMessage "Azure Web App Url: ${WEB_APP_SERVER}"


# Build dotnet-api docker image
printMessage "Building dotnet-rest-api container version:${APP_VERSION} port: ${APP_PORT}"
buildWebAppContainer "${ACR_LOGIN_SERVER}" "./src/dotnet-rest-api" "dotnet-rest-api" "${APP_VERSION}" "latest" ${APP_PORT}
checkError

# deploy dotnet-rest-api
printMessage "Deploy containers from Azure Container Registry ${ACR_LOGIN_SERVER}"
deployWebAppContainer "$AZURE_SUBSCRIPTION_ID" "$AZURE_APP_PREFIX" "${ACR_LOGIN_SERVER}" "${ACR_NAME}"  "dotnet-rest-api" "latest" "${APP_VERSION}" "${APP_PORT}"


# Test services
# Test dotnet-rest-api
dotnet_rest_api_url="https://${WEB_APP_SERVER}/version"
printMessage "Testing dotnet-rest-api url: $dotnet_rest_api_url expected version: ${APP_VERSION}"
result=$(checkUrl "${dotnet_rest_api_url}" "${APP_VERSION}" 420)
if [[ $result != "true" ]]; then
    printError "Error while testing dotnet-rest-api"
else
    printMessage "Testing dotnet-rest-api successful"
fi

# Undeploy Azure resource 
printMessage "Undeploying all the Azure resources"
undeployAzureInfrastructure $AZURE_SUBSCRIPTION_ID $AZURE_APP_PREFIX

echo "done."