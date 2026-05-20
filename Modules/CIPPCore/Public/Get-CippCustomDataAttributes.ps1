function Get-CippCustomDataAttributes {
    <#
    .SYNOPSIS
        Get the custom data attributes for CIPP
    .DESCRIPTION
        This function is used to get the custom data attributes for CIPP
    #>
    [CmdletBinding()]
    param(
        $TargetObject = 'All'
    )
    # Save the original parameter value before any foreach loops that use $TargetObject as
    # a loop variable - PowerShell foreach shares scope with the parent, so iterating with
    # the same name would clobber the parameter before the final Where-Object filter runs.
    $filterTargetObject = $TargetObject

    $CustomDataTable = Get-CippTable -tablename 'CustomData'
    $CustomDataEntities = Get-CIPPAzDataTableEntity @CustomDataTable
    $AvailableAttributes = foreach ($CustomDataEntity in $CustomDataEntities) {
        $Type = $CustomDataEntity.PartitionKey
        $CustomData = $CustomDataEntity.JSON | ConvertFrom-Json
        if ($CustomData) {
            if ($Type -eq 'SchemaExtension') {
                $Name = $CustomData.id
                foreach ($SchemaTargetType in $CustomData.targetTypes) {
                    foreach ($Property in $CustomData.properties) {
                        [PSCustomObject]@{
                            name          = '{0}.{1}' -f $Name, $Property.name
                            type          = $Type
                            targetObject  = $SchemaTargetType
                            dataType      = $Property.type
                            isMultiValued = $false
                        }
                    }
                }
            } elseif ($Type -eq 'DirectoryExtension') {
                $Name = $CustomDataEntity.RowKey
                foreach ($DirTargetObject in $CustomData.targetObjects) {
                    [PSCustomObject]@{
                        name          = $Name
                        type          = $Type
                        targetObject  = $DirTargetObject
                        dataType      = $CustomData.dataType
                        isMultiValued = $CustomData.isMultiValued
                    }
                }
            }
        }
    }

    if ($filterTargetObject -eq 'All') {
        return $AvailableAttributes
    } else {
        return $AvailableAttributes | Where-Object { $_.targetObject -eq $filterTargetObject }
    }
}
