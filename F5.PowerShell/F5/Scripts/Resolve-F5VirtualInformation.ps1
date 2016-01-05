function Resolve-F5VirtualInformation {
    param (
        [Parameter(Position = 0, Mandatory = $true, HelpMessage = "Please use the New-F5ConnectionInfo method to get connection info object.")]
        [object] $ConnectionInfo,

        [Alias("HostName")]
        [Parameter(Position = 1, Mandatory = $true, ParameterSetName = "Host", HelpMessage = "You must specify the DNS host name you want to check.")]
        [string] $DnsHost,
        
        [Alias("HostIP", "IP", "VIP")]
        [Parameter(Position = 1, Mandatory = $true, ParameterSetName = "VIP", HelpMessage = "You must specify the VIP address you want to check.")]
        [string] $HostVip,

        [Parameter(Position = 2)]
        [switch] $AsJson    = $false
    )
    begin {
		Write-Verbose "Resolve F5 Virtual Server Information";

        switch ($PSCmdlet.ParameterSetName) {
            "Host" { 
                $HostVip = [string](@([System.Net.Dns]::GetHostAddresses($DnsHost)) | Select-Object -First 1);
            }
            "VIP" {
                try {
                    $DnsHost = [string]([System.Net.Dns]::GetHostEntry($Vip) | Select-Object -ExpandProperty HostName);
                } catch {
                    $DnsHost = "[Unknown]";
                }
            }
        }
		Write-Verbose "Host/Vip: '$DnsHost'/'$HostVip'";
    }
    process {
        
        #region Grab all the VIPs and destination IPs from the BIG-IP
        
        $vipsX  = $(Invoke-RESTMethod -Method GET -Uri "$($ConnectionInfo.RestUri)/ltm/virtual" -Credential $ConnectionInfo.Credentials);
        $vipsF  = $vipsX.items | Select-Object name, destination, pool;

        #endregion

        #region Test the list of VIPs for the desired IP

        $vips   = @($vipsF | ?{$_.Destination -like "*$($HostVip)*"});
        if ($vips.Count -le 0) {
            throw "Could not find '$DnsHost' ($HostVip) in the list of VIPs on the BIG-IP";
            return;
        }

        #endregion

        #region Build the response

        # Loop through the VIPs
        $vipList = @();
        foreach ($vip in $vips) {
            # Get the pool
            $poolName   = $vip.pool -replace @("/Common/", "");
            if (![string]::IsNullOrEmpty($poolName)) {
                $pool       = $(Invoke-RESTMethod -Method GET -Uri "$($ConnectionInfo.RestUri)/ltm/pool/$($poolName)?expandSubcollections=true" -Credential $ConnectionInfo.Credentials);

                # Get the members
                $members = @($pool.membersReference.items | Select @("Name", "Address", "Session", "State"));

                # Add the pool to the pools list
                $vipList   += [PSCustomObject]@{
                    Name    = $vip.Name
                    Vip     = $vip.Destination -replace @('/Common/', '')
                    Pool    = [PSCustomObject] @{
                                    Name    = $poolName
                                    Members = $members
                                }
                };
            }
        }

        $ret = [PSCustomObject]@{
                    Hostname    = $DnsHost
                    Ip          = $vipList.Vip
                    Virtuals    = $vipList
                };

        #endregion

        #region Return the VIP information

        if ($AsJson) {
            return $ret | ConvertTo-Json -Depth 10;
        } else {
            return $ret;
        }

        #endregion
    }
}

Export-ModuleMember Resolve-F5VirtualInformation;