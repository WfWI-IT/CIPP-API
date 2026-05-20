function Get-CippCustomDataSelectRoots {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string[]]$CustomDataAttributes
  )

  $roots = foreach ($attr in $CustomDataAttributes) {
    if ([string]::IsNullOrWhiteSpace($attr)) { continue }

    # Schema extension mapping: extxxxx_schema.property
    if ($attr -like "ext*.*") {
      $attr.Split(".", 2)[0]
      continue
    }

    # Directory extension mapping: extension_<appid>_<name>
    if ($attr -like "extension_*") {
      $attr
      continue
    }
  }

  $roots | Sort-Object -Unique
}
