function Invoke-CIPPStandardInternalLabelPrinting {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) InternalLabelPrinting
    .SYNOPSIS
        (Label) Allow Printing for Internal Sensitivity Label
    .DESCRIPTION
        (Helptext) Ensures that Endpoint DLP rules do not block printing for content labeled as 'Internal'. Any DLP rule that targets the 'Internal' sensitivity label and restricts printing will have the print restriction removed.
        (DocsDescription) Finds Endpoint DLP compliance rules that target content with the 'Internal' sensitivity label and block printing via EndpointDlpRestrictions. When remediating, removes the print restriction from those rules so users can print Internal-labeled documents. Alert and report modes indicate whether any such blocking rules exist.
    .NOTES
        CAT
            Compliance Standards
        IMPACT
            Low Impact
        ADDEDDATE
            2026-05-21
        EXECUTIVETEXT
            Allows printing of documents labeled as 'Internal' by removing print blocks from Endpoint DLP rules that target the Internal sensitivity label.
        ADDEDCOMPONENT
        UPDATECOMMENTBLOCK
            Run the Tools\Update-StandardsComments.ps1 script to update this comment block
    .LINK
        https://docs.cipp.app/user-documentation/tenant/standards/list-standards
    #>

    param($Tenant, $Settings)

    $TestResult = Test-CIPPStandardLicense -StandardName 'InternalLabelPrinting' -TenantFilter $Tenant -Preset Compliance
    if ($TestResult -eq $false) { return $true }

    # Find the "Internal" sensitivity label to get its GUID
    $Labels = try {
        New-ExoRequest -tenantid $Tenant -cmdlet 'Get-Label' -Compliance
    } catch { @() }

    $InternalLabel = $Labels | Where-Object { $_.DisplayName -eq 'Internal' -or $_.Name -eq 'Internal' } | Select-Object -First 1

    if (-not $InternalLabel) {
        Write-LogMessage -API 'Standards' -tenant $Tenant -message "Standard InternalLabelPrinting: 'Internal' sensitivity label not found in tenant." -sev Warning
        return
    }

    # Collect all possible GUIDs/IDs for the Internal label to match against rule conditions
    $LabelIds = @(
        $InternalLabel.ImmutableId,
        $InternalLabel.Guid,
        $InternalLabel.ExchangeObjectId,
        $InternalLabel.Name,
        $InternalLabel.DisplayName
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    # Get all DLP compliance rules
    $AllRules = try {
        New-ExoRequest -tenantid $Tenant -cmdlet 'Get-DlpComplianceRule' -Compliance
    } catch { @() }

    # Find rules that block printing AND reference the Internal label
    $BlockingRules = @($AllRules | Where-Object {
        $rule = $_

        # Check for a Print block in EndpointDlpRestrictions
        $Restrictions = $rule.EndpointDlpRestrictions
        $HasPrintBlock = $false
        if ($Restrictions) {
            $HasPrintBlock = [bool](@($Restrictions) | Where-Object {
                    ($_ -is [hashtable] -and $_['Setting'] -eq 'Print' -and $_['Value'] -eq 'Block') -or
                    ($_.PSObject.Properties['Setting'] -and $_.Setting -eq 'Print' -and $_.Value -eq 'Block')
                })
        }
        if (-not $HasPrintBlock) { return $false }

        # Check whether the rule targets the Internal label via any known condition property
        $ReferencesInternal = $false
        foreach ($labelId in $LabelIds) {
            if (-not $labelId) { continue }
            $SensLabels = $rule.SensitivityLabels
            $ContainsLabel = $rule.ContentContainsSensitivityLabel
            if ($SensLabels -and (@($SensLabels) | Where-Object { $_ -match [regex]::Escape($labelId) })) { $ReferencesInternal = $true; break }
            if ($ContainsLabel -and (@($ContainsLabel) | Where-Object { $_ -match [regex]::Escape($labelId) })) { $ReferencesInternal = $true; break }
        }
        $ReferencesInternal
    })

    $PrintingAllowed = $BlockingRules.Count -eq 0

    if ($Settings.remediate -eq $true) {
        if ($PrintingAllowed) {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "InternalLabelPrinting: No DLP rules blocking printing for 'Internal' labeled content found." -sev Info
        } else {
            foreach ($Rule in $BlockingRules) {
                $Restrictions = @($Rule.EndpointDlpRestrictions)
                $NewRestrictions = @($Restrictions | Where-Object {
                        -not (
                            ($_ -is [hashtable] -and $_['Setting'] -eq 'Print') -or
                            ($_.PSObject.Properties['Setting'] -and $_.Setting -eq 'Print')
                        )
                    })

                $SetParams = @{ Identity = $Rule.Name }
                if ($NewRestrictions.Count -gt 0) {
                    $SetParams['EndpointDlpRestrictions'] = $NewRestrictions
                } else {
                    # Pass empty array to clear all restrictions; cmdlet accepts this to remove the property
                    $SetParams['EndpointDlpRestrictions'] = @()
                }

                try {
                    $null = New-ExoRequest -tenantid $Tenant -cmdlet 'Set-DlpComplianceRule' -cmdParams $SetParams -Compliance -useSystemMailbox $true
                    Write-LogMessage -API 'Standards' -tenant $Tenant -message "InternalLabelPrinting: Removed print restriction from DLP rule '$($Rule.Name)' (policy: $($Rule.ParentPolicyName))." -sev Info
                } catch {
                    $ErrorMessage = Get-CippException -Exception $_
                    Write-LogMessage -API 'Standards' -tenant $Tenant -message "InternalLabelPrinting: Failed to update DLP rule '$($Rule.Name)': $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
                }
            }
        }
    }

    if ($Settings.alert -eq $true) {
        if ($PrintingAllowed) {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "InternalLabelPrinting: Printing is allowed for 'Internal' labeled content." -sev Info
        } else {
            $BlockingRuleNames = ($BlockingRules | Select-Object -ExpandProperty Name) -join ', '
            Write-StandardsAlert -message "DLP rules are blocking printing for 'Internal' labeled content: $BlockingRuleNames" -object @{ BlockingRules = $BlockingRuleNames } -tenant $Tenant -standardName 'InternalLabelPrinting' -standardId $Settings.standardId
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "InternalLabelPrinting: DLP rules blocking printing for 'Internal' labeled content: $BlockingRuleNames" -sev Info
        }
    }

    if ($Settings.report -eq $true) {
        $CurrentValue = [PSCustomObject]@{ PrintingAllowed = $PrintingAllowed }
        $ExpectedValue = [PSCustomObject]@{ PrintingAllowed = $true }
        Set-CIPPStandardsCompareField -FieldName 'standards.InternalLabelPrinting' -CurrentValue $CurrentValue -ExpectedValue $ExpectedValue -TenantFilter $Tenant
        Add-CIPPBPAField -FieldName 'InternalLabelPrinting' -FieldValue $PrintingAllowed -StoreAs bool -Tenant $Tenant
    }
}
