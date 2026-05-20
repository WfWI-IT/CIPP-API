function Resolve-CippCustomDataValue {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$UserObject,

    [Parameter(Mandatory)]
    [string]$CustomDataAttribute
  )

  if ([string]::IsNullOrWhiteSpace($CustomDataAttribute)) { return $null }

  # Schema extension mapping: extxxxx_schema.property
  if ($CustomDataAttribute -like "ext*.*") {
    $parts = $CustomDataAttribute.Split(".", 2)
    $root = $parts[0]
    $leaf = $parts[1]

    $rootObj = $UserObject.$root
    if ($null -eq $rootObj) { return $null }

    return $rootObj.$leaf
  }

  # Directory extension mapping: extension_<appid>_<name>
  if ($CustomDataAttribute -like "extension_*") {
    return $UserObject.$CustomDataAttribute
  }

  return $null
}
