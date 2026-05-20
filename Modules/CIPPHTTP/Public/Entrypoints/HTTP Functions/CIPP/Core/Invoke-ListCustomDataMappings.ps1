function Invoke-ListCustomDataMappings {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $CustomDataMappingsTable = Get-CippTable -TableName 'CustomDataMappings'
    $TenantFilter = $Request.Query.tenantFilter
    $SourceTypeFilter = $Request.Query.sourceType
    $DirectoryObjectFilter = $Request.Query.directoryObject

    Write-Information "Listing custom data mappings with filters - sourceType: $SourceTypeFilter, directoryObject: $DirectoryObjectFilter, tenant: $TenantFilter"

    try {
        $Mappings = Get-CIPPAzDataTableEntity @CustomDataMappingsTable | ForEach-Object {
            $Mapping = $_.JSON | ConvertFrom-Json -AsHashtable

            # Filter by tenant: skip mappings that do NOT apply to the requested tenant
            # Expand-CIPPTenantGroups returns objects with a .value property (the domain name).
            # We must compare against .value strings, not the objects themselves.
            $TenantList = Expand-CIPPTenantGroups -TenantFilter $Mapping.tenantFilter
            $TenantDomains = @($TenantList.value)
            if ($TenantFilter -and ($TenantDomains -notcontains $TenantFilter -and $TenantDomains -notcontains 'AllTenants')) {
                return
            }

            $MappingObject = [PSCustomObject]@{
                id                    = $_.RowKey
                tenant                = $Mapping.tenantFilter.label
                dataset               = $Mapping.extensionSyncDataset.label
                sourceType            = $Mapping.sourceType.label
                directoryObject       = $Mapping.directoryObjectType.label
                syncProperty          = $Mapping.extensionSyncProperty.label ?? @($Mapping.extensionSyncDataset.addedFields.select -split ',')
                customDataAttribute   = $Mapping.customDataAttribute
                manualEntryFieldLabel = $Mapping.manualEntryFieldLabel
            }

            # Apply safe filtering
            $Include = $true
            if ($SourceTypeFilter -and $MappingObject.sourceType -ne $SourceTypeFilter) {
                $Include = $false
            }
            if ($DirectoryObjectFilter -and $MappingObject.directoryObject -ne $DirectoryObjectFilter) {
                $Include = $false
            }

            if ($Include) {
                return $MappingObject
            }
        } | Where-Object { $_ -ne $null }

        $Body = @{
            Results = @($Mappings)
        }
    } catch {
        $Body = @{
            Results = @(
                @{
                    state      = 'error'
                    resultText = "Failed to retrieve mappings: $($_.Exception.Message)"
                }
            )
        }
    }

    return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $Body
        })
}
