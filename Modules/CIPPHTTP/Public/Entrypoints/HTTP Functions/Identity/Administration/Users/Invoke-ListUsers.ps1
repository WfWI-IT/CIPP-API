using namespace System.Net

function Invoke-ListUsers {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Identity.User.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $ConversionTable = [System.IO.File]::ReadAllText((Join-Path $env:CIPPRootPath 'Config\ConversionTable.csv')) | ConvertFrom-Csv

    $TenantFilter = $Request.Query.tenantFilter
    $GraphFilter  = $Request.Query.graphFilter
    $UserId       = $Request.Query.UserID

    # Helper: flatten schema and directory extensions into the customData property.
    # Schema extensions are returned as NESTED objects (not flat dotted keys) so that
    # React Hook Form field paths like "customData.extXXX_schema.field" resolve correctly.
    function Add-CustomDataFlattening {
        param([Parameter(Mandatory)] $UserObject)

        $customDataOut = [pscustomobject]@{}

        foreach ($p in $UserObject.PSObject.Properties) {

            # Schema extension roots look like extxxxx_...; value is a nested object.
            # We re-expose the nested object under the same root key so that the
            # RHF path "customData.<root>.<leaf>" resolves to the correct value.
            if ($p.Name -like 'ext*' -and $null -ne $p.Value -and $p.Value.PSObject -and $p.Value.PSObject.Properties.Count -gt 0) {
                $nestedObj = [pscustomobject]@{}
                foreach ($leaf in $p.Value.PSObject.Properties) {
                    if ($leaf.Name -like '@odata.*') { continue }
                    $nestedObj | Add-Member -MemberType NoteProperty -Name $leaf.Name -Value $leaf.Value -Force
                }
                $customDataOut | Add-Member -MemberType NoteProperty -Name $p.Name -Value $nestedObj -Force
            }

            # Directory extension properties (if ever used)
            if ($p.Name -like 'extension_*') {
                $customDataOut | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
            }
        }

        $UserObject | Add-Member -MemberType NoteProperty -Name 'customData' -Value $customDataOut -Force
        return $UserObject
    }

    # Helper: add computed fields used by the UI
    function Add-UiComputedFields {
        param([Parameter(Mandatory)] $UserObject)

        $UserObject | Add-Member -MemberType NoteProperty -Name 'onPremisesSyncEnabled' -Value ([bool]($UserObject.onPremisesSyncEnabled)) -Force
        $UserObject | Add-Member -MemberType NoteProperty -Name 'username' -Value (($UserObject.userPrincipalName -split '@' | Select-Object -First 1)) -Force

        $proxy = @()
        if ($UserObject.proxyAddresses) { $proxy = @($UserObject.proxyAddresses) }
        $UserObject | Add-Member -MemberType NoteProperty -Name 'Aliases' -Value ($proxy -join ', ') -Force

        $SkuID = @()
        if ($UserObject.assignedLicenses) { $SkuID = @($UserObject.assignedLicenses.skuId) }
        $licJoined = @($SkuID | ForEach-Object {
            ($ConversionTable | Where-Object guid -EQ ([string]$_) | Select-Object -First 1 -ExpandProperty Product_Display_Name)
        }) -join ', '
        $UserObject | Add-Member -MemberType NoteProperty -Name 'LicJoined' -Value $licJoined -Force

        $prim = ($UserObject.userPrincipalName -split '@' | Select-Object -Last 1)
        $UserObject | Add-Member -MemberType NoteProperty -Name 'primDomain' -Value @{ value = $prim; label = $prim } -Force

        return $UserObject
    }

    try {
        $GraphRequest = if ($TenantFilter -ne 'AllTenants') {

            if (-not [string]::IsNullOrWhiteSpace($UserId)) {
                # Edit page load: single user fetch. Use v1.0 with explicit $select including schema extension roots.
                $selectFields = [System.Collections.Generic.List[string]]@(
                    'id',
                    'userPrincipalName',
                    'displayName',
                    'givenName',
                    'surname',
                    'mail',
                    'mailNickname',
                    'department',
                    'jobTitle',
                    'companyName',
                    'usageLocation',
                    'mobilePhone',
                    'streetAddress',
                    'city',
                    'state',
                    'postalCode',
                    'country',
                    'businessPhones',
                    'otherMails',
                    'proxyAddresses',
                    'assignedLicenses',
                    'onPremisesSyncEnabled'
                )
                # Dynamically add schema extension roots and directory extensions registered for users
                try {
                    $userAttrs = Get-CippCustomDataAttributes -TargetObject 'user'
                    if ($userAttrs) {
                        $schemaRoots = @(Get-CippCustomDataSelectRoots -CustomDataAttributes @($userAttrs.name))
                        foreach ($root in $schemaRoots) { $selectFields.Add($root) }
                    }
                } catch {
                    Write-Warning "Failed to load custom data attributes for user objects; custom extensions will not be included in `$select. Error: $($_.Exception.Message)"
                }
                $selectCsv = ($selectFields | Sort-Object -Unique) -join ','

                $user = New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/users/$($UserId)?`$select=$selectCsv&`$expand=manager(`$select=id,userPrincipalName,displayName)" -tenantid $TenantFilter

                $user = Add-UiComputedFields -UserObject $user
                $user = Add-CustomDataFlattening -UserObject $user
                $user
            }
            else {
                # Legacy list behavior (not the edit page). Keep it light; schema extensions are not included here.
                $selectFields = @(
                    'id',
                    'userPrincipalName',
                    'displayName',
                    'accountEnabled',
                    'assignedLicenses',
                    'proxyAddresses',
                    'onPremisesSyncEnabled'
                )
                $selectCsv = ($selectFields | Sort-Object -Unique) -join ','

                $uri = "https://graph.microsoft.com/beta/users?`$top=999&`$select=$selectCsv&`$expand=manager(`$select=id,userPrincipalName,displayName)"
                if (-not [string]::IsNullOrWhiteSpace($GraphFilter)) {
                    $uri += "&`$filter=$GraphFilter&`$count=true"
                }

                $users = New-GraphGetRequest -uri $uri -tenantid $TenantFilter -ComplexFilter

                @($users) | ForEach-Object {
                    $u = $_
                    $u = Add-UiComputedFields -UserObject $u
                    # Do not flatten schema extensions here unless you also select them
                    $u
                }
            }

        } else {
            # AllTenants branch (cached). Keep existing behavior and add customData flattening if ext* props exist in cache.
            $Table = Get-CIPPTable -TableName 'cacheusers'
            $Rows = Get-CIPPAzDataTableEntity @Table | Where-Object -Property Timestamp -GT (Get-Date).AddHours(-1)

            if (!$Rows) {
                [PSCustomObject]@{
                    Message = 'This function has been deprecated for all users, please use ListGraphRequest instead'
                }
            } else {
                $Rows.Data | ConvertFrom-Json | ForEach-Object {
                    $_.onPremisesSyncEnabled = [bool]($_.onPremisesSyncEnabled)
                    $_.Aliases = ($_.proxyAddresses -join ', ')
                    $SkuID = @()
                    if ($_.assignedLicenses) { $SkuID = @($_.assignedLicenses.skuId) }
                    $_.LicJoined = (@($SkuID | ForEach-Object { ($ConversionTable | Where-Object guid -EQ ([string]$_) | Select-Object -First 1 -ExpandProperty Product_Display_Name) }) -join ', ')
                    $_.primDomain = @{ value = ($_.userPrincipalName -split '@' | Select-Object -Last 1) }
                    $_ = Add-CustomDataFlattening -UserObject $_
                    $_
                }
            }
        }

        # Optional logon details enrichment
        if ($UserId -and $Request.Query.IncludeLogonDetails) {
            $startDate = (Get-Date).AddDays(-7)
            $endDate   = (Get-Date)
            $sessionid = Get-Random -Maximum 1000 -Minimum 1

            $upn = @($GraphRequest)[0].userPrincipalName

            $SearchParam = @{
                SessionCommand = 'ReturnLargeSet'
                Operations     = @('UserLoggedIn', 'UserLoginFailed', 'TeamsSessionStarted', 'MailboxLogin')
                sessionid      = $sessionid
                startDate      = $startDate
                endDate        = $endDate
                UserIds        = @($upn)
            }

            $AuditlogsLogon = (New-ExoRequest -tenantid $TenantFilter -cmdlet 'Search-unifiedAuditLog' -cmdParams $SearchParam |
                Sort-Object -Property CreationDate | Select-Object -Last 1).auditdata | ConvertFrom-Json

            $LastSignIn = [PSCustomObject]@{
                AppDisplayName  = "$($AuditlogsLogon.Workload) - $($AuditlogsLogon.ApplicationId)"
                CreatedDateTime = $AuditlogsLogon.CreationTime
                Id              = $AuditlogsLogon.errorNumber
                Status          = $AuditlogsLogon.ResultStatus
                Operation       = $AuditlogsLogon.operation
            }

            $GraphRequest = @($GraphRequest) | Select-Object *,
                @{ Name = 'LastSigninApplication';   Expression = { $LastSignIn.AppDisplayName } },
                @{ Name = 'LastSigninDate';          Expression = { $LastSignIn.CreatedDateTime } },
                @{ Name = 'LastSigninStatus';        Expression = { $LastSignIn.Operation } },
                @{ Name = 'LastSigninResult';        Expression = { $LastSignIn.Status } },
                @{ Name = 'LastSigninFailureReason'; Expression = { if ($LastSignIn.Id -eq 0) { 'Successfully signed in' } else { $LastSignIn.Id } } }
        }

        return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = @($GraphRequest)
        })

    } catch {
        $ErrorMessage = $_.Exception.Message
        return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = @([pscustomobject]@{ Error = $ErrorMessage })
        })
    }
}
