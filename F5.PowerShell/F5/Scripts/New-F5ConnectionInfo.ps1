function New-F5ConnectionInfo {
    param (
        [Alias("Host", "IP", "ComputerName", "MachineName")]
        [Parameter(Position = 0, Mandatory = $true, HelpMessage = "You must specify a hostname or IP for the BIG-IP")]
        [string] $Hostname,

        [Parameter(Position = 1, Mandatory = $true, HelpMessage = "You must specify admin credentials that can access iControlRest")]
        [PSCredential] $Credentials,

        [Parameter()]
        [switch] $Verify    = $true
    )
    process {
		
        #region Build the custom connection object

        $connInfo   = [PSCustomObject]@{
            Host        = $Hostname;
            Credentials = $Credentials;            
            RestUri     = "https://$($Hostname)/mgmt/tm";
        };

		#endregion

        #region Verify the connection info

        try {
            $test = Invoke-RestMethod -Method GET -Uri "$($connInfo.RestUri)/ltm/" -Credential $Credentials;
        } catch {
            throw "Connection verification failed. `nUri: '$($connInfo.RestUri)/ltm/'`nUsername: '$($Credentials.Username)'`nMessage: '$_'";
            return;
        }

		#endregion

        return $connInfo;
    }
}

Export-ModuleMember New-F5ConnectionInfo;