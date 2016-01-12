function Check-F5ApmCcuUsage {
    [CmdletBinding()]
    Param (
		[Parameter(Mandatory = $true, HelpMessage = "Please use the New-F5ConnectionInfo method to setup connection info")]
        [object] $ConnectionInfo
    )
    Process {
		Write-Verbose "Checking APM CCU usage on '$($ConnectionInfo.Host)'";

		$postData  = '{"command":"run","utilCmdArgs":"-c ''echo -e \"get tmm.license.global_connectivity#\r\" | nc 127.1.1.2 11211''"}';		
		Write-Verbose "  Data to send: '$postData'";
		$response  = $(Invoke-RestMethod -Method Post -Uri "$($ConnectionInfo.RestUri)/util/bash" -Body $postData -Credential $ConnectionInfo.Credentials -ContentType "application/json" -Verbose:$false -Debug:$false);
		$strResult = $response.commandResult;
		Write-Verbose "  Response: '$strResult'";
		
		$regex     = 'VALUE tmm.license.global_connectivity\W+\d+\W+\d+\W+(\d+)\W+END';
		if ($strResult -match $regex) {
			$return    = $Matches[1];
			Write-Verbose "  There are $return APM CCUs being used";
			return $return;
		} else {
			throw "  Unable to determine number of currently used APM CCUs";
			Write-Debug "Result: $strResult";
		}
    }
}

Export-ModuleMember Check-F5ApmCcuUsage;