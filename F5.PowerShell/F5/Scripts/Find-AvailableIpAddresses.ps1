#Find-AvailableIpAddresses -ConnectionInfo $conn -Ip "192.168.1.0/24" -CheckIp "192.168.1.222"
function Find-AvailableIpAddresses {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Please use the New-F5ConnectionInfo method to setup connection info.")]
        [object] $ConnectionInfo    ,

        [Parameter(Mandatory = $true, HelpMessage = "Use xxx.xxx.xxx.xxx/yy notation or just an IP address with the -Mask parameter")]
        [string] $Ip                ,

        [Parameter(HelpMessage = "Defaults to /24")]
        [string] $Mask              = "24",

        [Parameter(HelpMessage = "Checks for a specific IP availability")]
        [string] $CheckIp           = $null,

        [Parameter(ParameterSetName = "ListAll")]
        [switch] $ListAll           = $false
    )
    begin {
    }
    process {
        # $Debug        = $true
        # $Credentials  = Get-Credential mjenkins-a
        # $SourceProd   = $true

        Write-Verbose "Find Unused IP Addresses";
        Write-Verbose "-------------------------";
        Write-Verbose "  Ip range: $($Ip)";
        Write-Verbose "  Subnet mask: $($Mask)";

        #region Grab all the VIPs and destination IPs from the BIG-IP
        
        $vipsX      = $(Invoke-RESTMethod -Method GET -Uri "$($ConnectionInfo.RestUri)/ltm/virtual?`$select=name,destination" -Credential $ConnectionInfo.Credentials);
        $addresses  = @($vipsX.items | Select-Object -ExpandProperty destination) -replace @('(^/Common/)|([:].*$)',"") | Select-Object -Unique | Sort-Object;
        
        #endregion

        #region Check VIPs for specified IP

        $rangeInfo  = Get-NetworkSummary -IP $Ip -Mask $Mask;
        $rangeStart = ConvertTo-DecimalIP $rangeInfo.RangeStart;
        $rangeEnd   = ConvertTo-DecimalIP $rangeInfo.RangeEnd;

        $ret        = [PSCustomObject]@{Available=@();Unavailable=@()};

        # Check availability
        for ($ipDec = $rangeStart; $ipDec -le $rangeEnd; $ipDec++) {
            $tIp     = ConvertTo-DottedDecimalIP $ipDec;
            if ($addresses -contains $tIp) {
                $ret.Unavailable   += $tIp;
            } else {
                $ret.Available     += $tIp;
            }
        }

        #endregion

        #region Return data 

        if ($ListAll) { 
            return $ret; 
        } else {
            if ([string]::IsNullOrEmpty($CheckIp)) {
                return $ret.Available;
            } else {
                return $ret.Available -contains $CheckIp;
            }
        }

        #endregion
    }
}

Export-ModuleMember Find-AvailableIpAddresses;