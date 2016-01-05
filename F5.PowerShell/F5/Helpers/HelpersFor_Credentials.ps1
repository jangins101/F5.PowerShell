#region ---------- PSCredential ------------------------------------------------

## Author:     Hal Rottenberg <hal@halr9000.com>
## Url:        http://halr9000.com/article/tag/lib-authentication.ps1
## Purpose:    These functions allow one to easily save network credentials to disk in a relatively
##            secure manner.  The resulting on-disk credential file can only [1] be decrypted
##            by the same user account which performed the encryption.  For more details, see
##            the help files for ConvertFrom-SecureString and ConvertTo-SecureString as well as
##            MSDN pages about Windows Data Protection API.
##            [1]: So far as I know today.  Next week I'm sure a script kiddie will break it.
##
## Usage:    Export-PSCredential [-Credential <PSCredential object>] [-Path <file to export>]
##            Export-PSCredential [-Credential <username>] [-Path <file to export>]
##            If Credential is not specififed, user is prompted by Get-Credential cmdlet.
##            If a username is specified, then Get-Credential will prompt for password.
##            If the Path is not specififed, it will default to "./credentials.enc.xml".
##            Output: FileInfo object referring to saved credentials
##
##            Import-PSCredential [-Path <file to import>]
##
##            If not specififed, Path is "./credentials.enc.xml".
##            Output: PSCredential object
    
function Export-PSCredential {
    [CmdletBinding()]
    Param ( 
        [Parameter(Mandatory=$true)]
        [PSCredential]$Credential   ,
        [string]$Path               = $(Join-Path (Get-ScriptDirectory) "credentials.enc.$([Environment]::UserName).xml")
    )
    process {
        # Add the username to the path (if not there already)
        $Username   = [Environment]::UserName;
        $Extension  = [System.IO.Path]::GetExtension($Path);
        if ($Path -notlike "*$($Username)$($Extension)") {
            $Path   = [System.IO.Path]::ChangeExtension($Path, "$Username$Extension");
        }
            
        # Create temporary object to be serialized to disk
        $export     = [PSCustomObject]@{Username = ""; EncryptedPassword = $null};
            
        # Give object a type name which can be identified later
        $export.PSObject.TypeNames.Insert(0, 'ExportedPSCredential');
        $export.Username = $Credential.Username;

        # Encrypt SecureString password using Data Protection API
        # Only the current user account can decrypt this cipher
        $export.EncryptedPassword = $Credential.Password | ConvertFrom-SecureString;

        # Export using the Export-Clixml cmdlet
        $export | Export-Clixml $Path;
        Write-Verbose $('Credentials for "{0}" saved to "{1}"' -f @($export.Username, $Path));

        # Return path 
        Write-Output $($(Get-Item $Path).FullName);
    }
}

function Import-PSCredential {
    [CmdletBinding()]
    Param (
        [string]$Path               = $(Join-Path (Get-ScriptDirectory) "credentials.enc.$([Environment]::UserName).xml"),
        [switch]$AsNetworkCredential        
    )
    param ( $Path = "credentials.enc.xml", 
            [switch]$AsNetworkCredential )
    process {
        # Add the username to the path (if not there already)
        $Username   = [Environment]::UserName;
        $Extension  = [System.IO.Path]::GetExtension($Path);
        if ($Path -notlike "*$($Username)$($Extension)") {
            $Path   = [System.IO.Path]::ChangeExtension($Path, "$Username$Extension");
        }
            
        # Import credential file
        $import     = Import-Clixml $Path;
            
        # Test for valid import
        if ( !$import.UserName -or !$import.EncryptedPassword ) {
            throw "Input is not a valid ExportedPSCredential object, exiting."
        }
        $Username   = $import.Username
            
        # Decrypt the password and store as a SecureString object for safekeeping
        $SecurePass = $import.EncryptedPassword | ConvertTo-SecureString
            
        # Build the new credential object
        $Credential = New-Object System.Management.Automation.PSCredential $Username, $SecurePass
            
        if ($AsNetworkCredential -eq $true) {
            Write-Output $Credential.GetNetworkCredential();
        } else {
            Write-Output $Credential;
        }
    }
}