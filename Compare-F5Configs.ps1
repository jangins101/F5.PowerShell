Param (
    # Debugging
    [switch]$Debug              = $false,
    
    # Source Configuration
    [string] $SourceHost        ,
    [PSCredential] $SourceCred  = $(Get-Credential -Message "Source BIG-IP Credential"),
    
    # Destination Configuration
    [string] $DestHost          ,
    [PSCredential] $DestCred    = $(Get-Credential -Message "Destination BIG-IP Credential"),

    # Compare exacts (without removing arbitrary differences)
    [switch] $CompareExact      = $false,

    [string]$PlinkPath
)
Begin {
    $connSrc = [PSCustomObject]@{ Server = $SourceHost; Credentials = $SourceCred };
    $connDst = [PSCustomObject]@{ Server = $DestHost;   Credentials = $DestCred   };
}
Process {
    if ($isDebug -or $Debug) {
        $VerbosePreference= "continue";
        Write-Verbose "Sync Check for F5 devices";
    }
    
    #region Functions

    function ArrayToHash($array) {
        $ht     = @{};
        $array  | %{ $ht.Add($_.Name, $_.Value); };
        return $ht;
    }
    function ConvertTo-PSObject([array]$array, $nameField = "Name") {
        $obj = "" | Select-Object @(($array | Select-Object -ExpandProperty $nameField));
        $($obj | Get-Member -MemberType NoteProperty) | %{
            $name = $_.Name;
            $obj.$name = ($array | ?{ $_.$nameField -eq $name });
        };
        return $obj;
    }

    function Get-F5ConfigFor($type, $connection) {
        # Build the PLINK command to get the data from server
        $command            = ".\PLINK.EXE -l ""{0}"" -pw ""{1}"" {2} ""tmsh list / {3}""" -f @($connection.Credentials.Username, `
                                                                                                $connection.Credentials.GetNetworkCredential().Password, `
                                                                                                $connection.Server, $type);
        Write-Verbose $("Command: '.\PLINK.EXE -l ""{0}"" -pw ""{1}"" {2} ""tmsh list / {3}""'" -f @($connection.Credentials.Username, "**********" , $connection.Server, $type));

        # Run the command on the server
        $result = Invoke-Expression $command;         
        # Results is array of lines. Join them as a string
        $return = $result -join "`n";
        
        return $return;
    }
    function Get-ConfigDataFromF5($checkType, $connection) {
        $props              = @("Result", "ResultStr", "Lines", "LinesMin", "LinesNamed", "LinesMinNamed", "DiffLines", "DiffLinesMin", "MissingLines", "MissingLinesMin", "ExtraLines", "ExtraLinesMin");
        $configType         = "$($checkType.Module) $($checkType.Type)";
        
        # Build the PLINK command to get the data from server
        $command            = ".\PLINK.EXE -l ""{0}"" -pw ""{1}"" {2} ""tmsh list / {3}""" -f @($connection.Credentials.Username, `
                                                                                                $connection.Credentials.GetNetworkCredential().Password, `
                                                                                                $connection.Server, $configType);
        Write-Verbose $("      Command: '.\PLINK.EXE -l ""{0}"" -pw ""{1}"" {2} ""tmsh list / {3}""'" -f @($connection.Credentials.Username, "**********" , $connection.Server, $configType));

        Write-Verbose "      Getting config from $($connection.Server)";

        # Build the custom object so we can populate the fields
        $obj                =  $("" | Select-Object $props);

        # Run the command on the server
        $obj.Result         = Invoke-Expression $command;   
         
        # Results is array of lines. Join them as a string
        $obj.ResultStr      = $obj.Result -join "`n";

        # Perform conversion if specified

        # Split the string on the config type (e.g. ltm virtual) so we can have each individual entry
        $obj.Lines          = @($obj.ResultStr.Split(@($configType), [System.StringSplitOptions]::RemoveEmptyEntries)); 
        Write-Verbose "        $($obj.Lines.Count) lines retrieved";
        
        # Minify each Line (remove line breaks and extra whitespace)
        $obj.LinesMin       = $obj.Lines    | %{ $($_ -replace @("`n"," ") -replace @("\s+"," ")).Trim() };

        # Build lookups by name for lines
        $obj.LinesNamed     = $obj.Lines    | Select-Object @{ Name="Name"; Expression={ [void]$($_ -match "^[^\{]*"); $Matches[0].Trim() } }, `
                                                            @{ Name="Value";Expression={ "$($configType)$($_)" } };
        # Build lookups by name for minified lines
        $obj.LinesMinNamed  = $obj.LinesMin | Select-Object @{ Name="Name"; Expression={ [void]$($_ -match "^[^\{]*"); $Matches[0].Trim() } }, `
                                                            @{ Name="Value";Expression={ "$($configType)$($_)" } };
        
        # Null out the sections we're not working on yet
        $obj.DiffLines      = @();
        $obj.MissingLines   = @();
        $obj.ExtraLines     = @();

        return $obj;
    }

    function Check-DifferenceBetweenLines($linesA, $linesB, $conversion) {
        # Grab the right conversion function
        if ("$conversion" -eq "") { $fcn = (Get-Item function:fcnEmpty) } else { $fcn = (Get-Item function:$conversion) }

        # For each line in linesA, check for an exact (case sensitive) name match,
        #   and grab the lines if their definitions aren't a match
        $diffLines  = @($linesA | ?{$a = $_; `
                                    $b = $($linesB | ?{ $_.Name -ceq  $a.Name}); `
                                    return $(($b -ne $null) -and ((& $fcn $a.Value) -cne (& $fcn $b.Value))) });
        # Get the names of each of the differences
        $diffNames  = $diffLines | Select-Object -ExpandProperty Name;
        # Build the return object with name, and values for source and destination lines
        $retObj     = $diffNames | Select-Object    @{ Name = "Name";   Expression = { $_ } }, `
                                                    @{ Name = "Source"; Expression = { $n = $_; ($linesA | ?{ $_.Name -ceq $n }).Value } }, `
                                                    @{ Name = "Dest";   Expression = { $n = $_; ($linesB | ?{ $_.Name -ceq $n }).Value } };
        return $retObj;
    }
    function Check-MissingLines($linesA, $linesB) {
        return @($linesA | ?{ @($linesB | Select-Object -ExpandProperty Name) -cnotcontains $_.Name });
    }

    function Filter-OnlyUppercase($linesNamed) {
        $ret = $linesNamed | ?{ $_.Name -cnotmatch "[a-z]+" };
        return $ret;
    }

    function fcnEmpty ($str) { return $str }

    #endregion

    #region Get PLINK executable path
    
    Write-Verbose "Searching for PLINK.exe";

    function Get-PlinkPath() {
        # Return and break both screw up when running script, so we'll use a function
        $plinkInfo  = $null;
        $drives     = @(Get-PSDrive -PSProvider "FileSystem" | Where-Object -Property Free);
        foreach ($drive in $drives) {
            Write-Verbose "  Checking $($drive.Root)";

            # Get subdirectories for drive
            $dirs = $(Get-ChildItem -Path $drive.Root -Directory);

            foreach ($dir in $dirs) {
                # Look for the PLINK executable in the current dir (recursive check)
                $plinkInfo  = Get-ChildItem -Path $dir.FullName -Filter "plink.exe" -Recurse -ErrorAction SilentlyContinue;
                
                # Break out of this inner foreach (DIR)
                if ($plinkInfo -ne $null) { break; }
            }
            
            # Double check that we found the file, and break the outer foreach (DRIVE)
            if ($plinkInfo -ne $null) { 
                Write-Verbose "    FOUND IT [$($plinkInfo.FullName)]";  
                Write-Output $($plinkInfo.FullName); 
                break;
            } 
        }

        if ($plinkInfo -eq $null) { throw "Putty must be installed for this to work (this script uses plink.exe to connect to the servers)"; }
    }
    
    # Get the PLINK executable path
    if (Test-Path $PlinkPath) {
        $plink = $PlinkPath;
    } else {
        $plink  = Get-PlinkPath;
    }

    Push-Location $(Split-Path $plink);

    #endregion  

    #region Custom Processing Functions/ScriptBlocks

    #region Examples

    if ($false) {
        # Scriptblock examples
        $fcnConvertExample  = {param($line) $line.Value = $line.Value -replace @("xxx", "yyy"); $line; };
        $fcnFilterExample   = {param($line) if ($line -like "*xxx*") { return $line } };

        # Function examples
        function fcnConvertExample ($line) {
            $line.Value = $line.Value -replace @("xxx", "yyy");
            $line;
        }
        function fcnFilterExample ($line) {
            if ($line -like "*xxx*") { 
                return $line 
            } 
        }
    }

    #endregion
    
    #region Conversions
    
    function fcnConvertVirtuals ($line) {
        # Trim the line and remove vs-index value
        $line.Value = $line.Value   -replace @("\s+", " ") `
                                    -replace ('(vs-index) .*', '##### $1 REMOVED');
        $line;
    }
    function fcnConvertRules ($line) {
        # Trim the beginning of the iRules because listing them adds extra space
        $line.Value = $line.Value -replace @("(ltm rule \w+ {\n)\s+",'$1');
        $line;
    }
    function fcnConvertMonitors ($line) {
        # Make a note that we need to manually update monitors containing passwords, because of the encryption
        if ($line.Value -match 'password [a-z0-9\$/=+]+' ) {
            $line.value = $line.value   -replace @("(^.*)(\n)"                  , '##### Password redacted due to arbitrary value | $2$1$2') `
                                        -replace @("(\n)"                       , '$1#') `
                                        -replace @("password [a-z0-9\$/=+]+"    , "##### Removed password text (so we don't find false inequality)");
        }
    }
    function fcnConvertPools ($line) {
        # Remove the state value to elimate false positives
        $line.Value = $line.Value       -replace @("state (down|up|checking)", "# state REMOVED");
        $line; 
    }
    function fcnConvertLtmProfile ($line) {
        # Make a note that we need to manually update encrypted values
        if ($line.Value -match 'encrypted|secret|passphrase') {
            $line.value = $line.value   -replace @("(^.*)(\n)"                                  , '##### THIS PROFILE MUST BE UPDATED MANUALLY DUE TO CONTAINING ENCRYPTED STRINGS ##### $2$1$2') `
                                        -replace @("(\n)"                                       , '$1#') `
                                        -replace @("(\S*(?:encrypted|secret|passphrase)) ([a-z0-9\$/=+]+)", 'Removed $1 (so we don''t find false inequality)');
        }
    }
    function fcnConvertLtmSsl ($line) {
        # Make a note that we need to manually update encrypted values
        if ($line.Value -match 'passphrase') {
            $line.value = $line.value   -replace @("(^.*)(\n)"                                  , '##### THIS PROFILE MUST BE UPDATED MANUALLY DUE TO CONTAINING ENCRYPTED STRINGS ##### $2$1$2') `
                                        -replace @("(\n)"                                       , '$1#') `
                                        -replace @("(\S*(?:passphrase)) ([a-z0-9\$/=+]+)", 'Removed $1 (so we don''t find false inequality)');
        }
    }
    function fcnConvertLtmPersistence ($line) {
        # Make a note that we need to manually update encrypted values
        if ($line.Value -match 'cookie-encryption-passphrase') {
            $line.value = $line.value   -replace @("(^.*)(\n)"                                  , '##### THIS PROFILE MUST BE UPDATED MANUALLY DUE TO CONTAINING ENCRYPTED STRINGS ##### $2$1$2') `
                                        -replace @("(\n)"                                       , '$1#') `
                                        -replace @("(\S*(?:cookie-encryption-passphrase)) ([a-z0-9\$/=+]+)", 'Removed $1 (so we don''t find false inequality)');
        }
    }
    function fcnConvertApmAaa ($line) {
        # Make a note that we need to manually update encrypted values
        if ($line.Value -match 'admin-encrypted-password [a-z0-9\$/=+]+' ) {
            $line.value = $line.value   -replace @("(^.*)(\n)"                                  , '##### THIS AAA MUST BE UPDATED MANUALLY DUE TO PASSWORD ENCRYPTION ##### $2$1$2') `
                                        -replace @("(\n)"                                       , '$1#') `
                                        -replace @("admin-encrypted-password [a-z0-9\$/=+]+"    , "Removed password text (so we don't find false inequality)");
        }
    }
    function fcnConvertApmPolicy ($line) {
        $line.Value = $line.Value       -replace @("(checksum|create-time|created-by|last-update-time|revision|updated-by|mode|size).*", '# Removed $1');
        $line;
    }
    function fcnConvertApmResource ($line) {
        $line;
    }
    function fcnConvertApmSso ($line) {
        $line.Value = $line.Value       -replace @('(account-password).*', '# $1 ### REMOVED'); # Remove the encrypted password because we know it won't be the same
        $line;
    }
    
    #endregion 

    #region Filters

    function fcnFilterClientSsl($line) {
        if ($line.Value -match "ltm profile client-ssl [^{]*[a-z]+[^{]*{\n") {
            return "# FILTERED OUT: $($line.Name)";
        }
    }
    function fcnFilterVirtuals($line) {
        return $line;
    }

    #endregion

    #region Comparisons 

    function fcnCompareLines($lineSrc, $lineDst) {        
        # Compare is inequal
        return $false;

        # Compare is equal
        return $true;
    }

    #endregion

    #endregion

    #region Create base checktype objects

    $checkTypes = @(
        [PSCustomObject]@{ Id = "ltmDataGroup";     Module = "ltm";     Type = "data-group";            },
        [PSCustomObject]@{ Id = "ltmProfile";       Module = "ltm";     Type = "profile";               Conversion = "fcnConvertLtmProfile" },
        [PSCustomObject]@{ Id = "ltmClientSsl";     Module = "ltm";     Type = "profile client-ssl";    Conversion = "fcnConvertLtmSsl"; Filter = "fcnFilterVirtuals" },
        [PSCustomObject]@{ Id = "ltmServerSsl";     Module = "ltm";     Type = "profile server-ssl";    Conversion = "fcnConvertLtmSsl" },
        [PSCustomObject]@{ Id = "ltmPersistence";   Module = "ltm";     Type = "persistence";           Conversion = "fcnConvertLtmPersistence" },
        [PSCustomObject]@{ Id = "ltmPolicy";        Module = "ltm";     Type = "policy";                },
        [PSCustomObject]@{ Id = "ltmNode";          Module = "ltm";     Type = "node";                  Conversion = "fcnConvertPools" },
        [PSCustomObject]@{ Id = "ltmMonitor";       Module = "ltm";     Type = "monitor";               Conversion = "fcnConvertMonitors" },
        [PSCustomObject]@{ Id = "ltmPool";          Module = "ltm";     Type = "pool";                  Conversion = "fcnConvertPools" },
        [PSCustomObject]@{ Id = "ltmRule";          Module = "ltm";     Type = "rule";                  Conversion = "fcnConvertRules" },
        [PSCustomObject]@{ Id = "ltmVirtual";       Module = "ltm";     Type = "virtual";               Conversion = "fcnConvertVirtuals";  Filter = "fcnFilterVirtuals" },
        
        
        [PSCustomObject]@{ Id = "apmAcl";           Module = "apm";     Type = "acl";                   },
        [PSCustomObject]@{ Id = "apmAaa";           Module = "apm";     Type = "aaa";                   Conversion = "fcnConvertApmAaa"},
        [PSCustomObject]@{ Id = "apmPolicy";        Module = "apm";     Type = "policy";                Conversion = "fcnConvertApmPolicy" },
        [PSCustomObject]@{ Id = "apmProfile";       Module = "apm";     Type = "profile";               },
        [PSCustomObject]@{ Id = "apmResource";      Module = "apm";     Type = "resource";              Conversion = "fcnConvertApmResource" },
        [PSCustomObject]@{ Id = "apmSso";           Module = "apm";     Type = "sso";                   },

        [PSCustomObject]@{ Id = "auth";             Module = "auth";    Type = "";                      }
    );
    $config = ConvertTo-PSObject $checkTypes "Id";
    
    #endregion

    #region Get the data

    Write-Verbose "  Gathering data from servers";
    $checkTypes | %{
        $checkType  = $_;
        Write-Verbose "    $($checkType.Module) $($checkType.Type)";

        # Get the config data
        Invoke-Command -NoNewScope -ScriptBlock  {
            # Add Source/Destination members 
            $checkType | Add-Member -MemberType NoteProperty -Name Source           -Value $(Get-ConfigDataFromF5 $checkType $connSrc);
            $checkType | Add-Member -MemberType NoteProperty -Name Dest             -Value $(Get-ConfigDataFromF5 $checkType $connDst);

            # Add the config logging members to each checktype (minimizes initialization code above)
            $checkType | Add-Member -MemberType NoteProperty -Name RollbackConfig   -Value $([PSCustomObject]@{ 
                                                                                                Insert  = $(New-Object System.Text.StringBuilder);
                                                                                                Update  = $(New-Object System.Text.StringBuilder);
                                                                                                Delete  = $(New-Object System.Text.StringBuilder);
                                                                                            });
            $checkType | Add-Member -MemberType NoteProperty -Name MergeConfig      -Value $([PSCustomObject]@{ 
                                                                                                Insert  = $(New-Object System.Text.StringBuilder);
                                                                                                Update  = $(New-Object System.Text.StringBuilder);
                                                                                                Delete  = $(New-Object System.Text.StringBuilder);
                                                                                            });
            
            # Add the Conversion member if it doesn't exist
            if ( $($checkType | Get-Member -Name "Conversion") -eq $null ) {
                $checkType | Add-Member -MemberType NoteProperty -Name Conversion   -Value $null;
            }
            
            # Add the Filter member if it doesn't exist
            if ( $($checkType | Get-Member -Name "Filter") -eq $null ) {
                $checkType | Add-Member -MemberType NoteProperty -Name Filter       -Value $null;
            }
        }
    }

    #endregion

    #region Build merge/rollback configs
    
    #region Functions 

    # Append a given string to all stringbuilders in the array
    function Append-ToSBList([Array]$sbList, $msg) {
        $sbList | %{ [Void]$_.AppendLine($msg); }
    }

    # Execute convertion function if specified (error if not exists)
    function Convert-LinesNamed($fcnName, $linesNamed) {
        # Check to see if we even want to use a conversion function
        if ( [string]::IsNullOrEmpty($fcnName)) { 
            #Write-Output $linesNamed;
            return;
        }

        # Verify the conversion function exists
        if ( $fcnName -is [string] ) {
            $cmd = Get-Command $fcnName;
            if ( $cmd -eq $null ) { throw "Conversion function ($fcnName) was not found. Please verify that exists"; return; }
            $fcnConvert = [ScriptBlock]$cmd.ScriptBlock;
        } elseif  ( $fcnName -is [ScriptBlock] ) {
            $fcnConvert = [ScriptBlock]$fcnName;
        } else {
            throw "Could not parse conversion function ($fcnName) from it type ($($fcnname.GetType().Name))";
            return;
        }

        # Convert each named line and add to output
        $linesNamed  | % {
            $line   = $_;
            $lineC  = . $fcnConvert $line;
            #Write-Output $lineC;
        }
    }

    # Execute conversion function if specified 
    function Convert-LineNamed($fcnName, $lineNamedSrc, $lineNamedDest) {
        # Check to see if we even want to use a conversion function
        if ( [string]::IsNullOrEmpty($fcnName)) { 
            #Write-Output $linesNamed;
            return;
        }

        # Verify the conversion function exists
        if ( $fcnName -is [string] ) {
            $cmd = Get-Command $fcnName;
            if ( $cmd -eq $null ) { throw "Conversion function ($fcnName) was not found. Please verify that exists"; return; }
            $fcnConvert = [ScriptBlock]$cmd.ScriptBlock;
        } elseif  ( $fcnName -is [ScriptBlock] ) {
            $fcnConvert = [ScriptBlock]$fcnName;
        } else {
            throw "Could not parse conversion function ($fcnName) from it type ($($fcnname.GetType().Name))";
            return;
        }

        # Convert the named lines
        . $fcnConvert ([ref]$lineNamedSrc) ([ref]$lineNamedDest);
    }

    # Append name to list of changes
    function Append-ToChangeList($changeType, $module, $name) {
        #Write-Verbose "$changeType '$module' named '$name'";

        # Check for change type
        if ( !($listChanges.ContainsKey($changeType)) ) {
            $listChanges.Add($changeType, @{});
        }

        # Check for module
        if ( !($listChanges[$changeType].ContainsKey($module)) ) {
            $listChanges[$changeType].Add($module, @());
        }

        # Add the name
        $listChanges[$changeType][$module] += $name;
    }

    #endregion

    #region Process data

    Write-Verbose "  Processing the data (checking sync status for items)";

    # Aggregation of all the changes 
    $listChanges        = @{};

    # Process each checktype
    $checkTypes | %{
        $checkType      = $_;
        Write-Verbose "    $($checkType.Module) $($checkType.Type)";

        #region Group the loggers (stringbuilders)

        $sbListInserts  = @($checkType.RollbackConfig.Insert, $checkType.MergeConfig.Insert);
        $sbListUpdates  = @($checkType.RollbackConfig.Update, $checkType.MergeConfig.Update);
        $sbListDeletes  = @($checkType.RollbackConfig.Delete, $checkType.MergeConfig.Delete);    
        $sbListAll      = @($sbListInserts + $sbListUpdates + $sbListDeletes);

        #endregion
                
        #region Headers 
        
        Append-ToSBList $sbListAll "##################################################";
        Append-ToSBList $sbListAll "#####  $($checkType.Module) $($checkType.Type)";
        Append-ToSBList $sbListAll "##################################################";
        Append-ToSBList $sbListAll "";
                
        #endregion

        #region Named Lines

        $srcNamed   = $checkType.Source.LinesNamed;
        $destNamed  = $checkType.Dest.LinesNamed;

        # Get the conversion function for this check type
        Convert-LinesNamed $checkType.Conversion $srcNamed;
        Convert-LinesNamed $checkType.Conversion $destNamed;

        #endregion

        #region Loop through the Source lines (INSERTs && UPDATEs)
         
        $srcNamed | %{ 
            $srcLineNamed = $_;
            $destLineNamed = $destNamed | ?{ $_.Name -ceq $srcLineNamed.Name }
            
            # Convert the line (using source and destination for matching/manipulating)
            #TODO: Convert-LineNamed $checkType .Conversion $srcLineNamed $destLineNamed;

            $srcLength  = @($srcLineNamed.Value -split "\n").Count;
            $destLength = @($destLineNamed.Value -split "\n").Count;

            $logMsg = "  ";

            # INSERT    | Object should be created on the destination server
            if ( $destLineNamed -eq $null ) {
                $logMsg += "INSERT  ";
                Append-ToSBList $sbListInserts                      "# $($srcLineNamed.Name)";
                Append-ToSBList @($checkType.MergeConfig.Insert)    $srcLineNamed.Value;
                Append-ToSBList @($checkType.RollbackConfig.Insert) "##### tmsh delete $($checkType.Module) $($checkType.Type) $($srcLineNamed.Name)";
                Append-ToSBList @($checkType.RollbackConfig.Insert) "";

                Append-ToChangeList "Insert" "$($checkType.Module) $($checkType.Type)" $($srcLineNamed.Name);
            }

            # UPDATE    | Object should be updated on the destination server
            if ( ($destLineNamed -ne $null) -and ($srcLineNamed.Value -ne $destLineNamed.Value) ) {
                $logMsg += "UPDATE  ";
                
                Append-ToSBList $sbListUpdates                      "# $($srcLineNamed.Name)";
                Append-ToSBList @($checkType.MergeConfig.Update)    $srcLineNamed.Value;
                Append-ToSBList @($checkType.RollbackConfig.Update) $destLineNamed.Value;
                
                # Pad the merge file so line numbers add up correctly                
                if ($srcLength -lt $destLength) {
                    # Pad source with empty lines
                    @(($srcLength+1)..$destLength) | %{ Append-ToSBList @($checkType.MergeConfig.Update) ""; }
                } elseif ($srcLength -gt $destLength) {
                    # Pad destination with empty lines
                    @(($srcLength+1)..$destLength) | %{ Append-ToSBList @($checkType.RollbackConfig.Update) ""; }
                }

                Append-ToChangeList "Update" "$($checkType.Module) $($checkType.Type)" $($srcLineNamed.Name);
            }

            # EQUAL     | Object should be ignored because it's the same in both
            if ( $srcLineNamed.Value -eq $destLineNamed.Value ) {
                $logMsg += "EQUAL   ";
            }

            $logMsg  += "| $($srcLineNamed.Name) ";

            Write-Verbose "    $logMsg";
        }

        #endregion

        #region Loop through the Destination lines 

        $destNamed | %{ 
            $destLineNamed = $_;
            $srcLineNamed  = $srcNamed | ?{ $_.Name -ceq $destLineNamed.Name }

            # DELETE    | Object should be deleted on the destination server
            if ( $srcLineNamed -eq $null ) {
                Write-Verbose "      DELETE  | $($destLineNamed.Name) ";


                Append-ToSBList $sbListDeletes                      "# $($destLineNamed.Name)";
                Append-ToSBList @($checkType.MergeConfig.Delete)    "##### tmsh delete $($checkType.Module) $($checkType.Type) $($destLineNamed.Name)";
                Append-ToSBList @($checkType.MergeConfig.Delete)    "";
                Append-ToSBList @($checkType.RollbackConfig.Delete) $destLineNamed.Value;

                Append-ToChangeList "Delete" "$($checkType.Module) $($checkType.Type)" $($destLineNamed.Name);
            }
        }

        #endregion

        Append-ToSBList $sbListAll "";
    }
    
    #endregion

    #endregion

    #region Export merge files
    
    #region Create output dir if not existent
    
    $outDir     = "C:\Temp\F5\MergeConfigs\";
    $outDirR    = "C:\Temp\F5\MergeConfigs\Rollback\";
    $outDirM    = "C:\Temp\F5\MergeConfigs\Merge\";

    @($outDir, $outDirR, $outDirM) | %{
        if ( !($(Test-Path $_)) ) {
            [Void](New-Item -Path $_ -ItemType "D");
        }
    }

    #endregion

    Push-Location $outDir;

    #region Backups for existing files

    if (Test-Path -Path  "Summary.Report.log") {
        Write-Host "`n`nWould you like to backup the current files before exporting new ones?" -ForegroundColor White;
        Write-Host "  (Y)es or (N)o | Default: Y" -ForegroundColor White;
        $backup = Read-Host -Prompt  "Please enter Y or N";

        if ($backup -ne "n") {
            $file = Get-ChildItem Summary.Report.log;
            $bakPath = $($file.LastWriteTime.ToString("yyyy.MM.dd HHmm")) ;
            New-Item -Path $bakPath  -ItemType "D" | Out-Null;

            Get-Item -Path @("Merge", "Rollback", "Summary.Report.csv", "Summary.Report.log") `
                | Move-Item -Destination $bakPath;
        }
    }

    #endregion

    Write-Verbose "  Writing config files to '$outDir'";

    # Save the individual configs for each module
    $checkTypes | %{
        $checkType = $_;
        
        $isDifferentInserts = ("$($checkType.RollbackConfig.Insert)" -ne "$($checkType.MergeConfig.Insert)");
        $isDifferentUpdates = ("$($checkType.RollbackConfig.Update)" -ne "$($checkType.MergeConfig.Update)");
        $isDifferentDeletes = ("$($checkType.RollbackConfig.Delete)" -ne "$($checkType.MergeConfig.Delete)");

        # Ignore if there are no differences
        if ($isDifferentInserts -or $isDifferentUpdates -or $isDifferentDeletes) {
            #region Create checktype directories if not existent
        
            $tOutDirR   = Join-Path $outDirR $($checkType.Id);
            $tOutDirM   = Join-Path $outDirM $($checkType.Id);
            @($tOutDirR, $tOutDirM) | %{
                if ( !($(Test-Path $_)) ) {
                    [Void](New-Item -Path $_ -ItemType "D");
                }
            }

            #endregion

            # INSERTS
            if ("$($checkType.RollbackConfig.Insert)" -ne "$($checkType.MergeConfig.Insert)") {
                "$($checkType.RollbackConfig.Insert)"   | Out-File $(Join-Path $tOutDirR "$($checkType.Id).insert.merge.config") -Encoding Default;
                "$($checkType.MergeConfig.Insert)"      | Out-File $(Join-Path $tOutDirM "$($checkType.Id).insert.merge.config") -Encoding Default;
            }

            # UPDATES
            if ("$($checkType.RollbackConfig.Update)" -ne "$($checkType.MergeConfig.Update)") {
                "$($checkType.RollbackConfig.Update)"   | Out-File $(Join-Path $tOutDirR "$($checkType.Id).update.merge.config") -Encoding Default
                "$($checkType.MergeConfig.Update)"      | Out-File $(Join-Path $tOutDirM "$($checkType.Id).update.merge.config") -Encoding Default;
            }

            # DELETES
            if ("$($checkType.RollbackConfig.Delete)" -ne "$($checkType.MergeConfig.Delete)") {
                "$($checkType.RollbackConfig.Delete)"   | Out-File $(Join-Path $tOutDirR "$($checkType.Id).delete.merge.config") -Encoding Default;
                "$($checkType.MergeConfig.Delete)"      | Out-File $(Join-Path $tOutDirM "$($checkType.Id).delete.merge.config") -Encoding Default;
            }
        }
    }

    # Group the modules into single files
    $($checktypes| Select-Object @{Name="Out";Expression={"$($_.RollbackConfig.Insert)"}}   | %{$_.Out})  | Out-File $(Join-Path $outDirR "insert.merge.config")    -Encoding Default;
    $($checktypes| Select-Object @{Name="Out";Expression={"$($_.MergeConfig.Insert)"}}      | %{$_.Out})  | Out-File $(Join-Path $outDirm "insert.merge.config")    -Encoding Default;

    $($checktypes| Select-Object @{Name="Out";Expression={"$($_.RollbackConfig.Update)"}}   | %{$_.Out})  | Out-File $(Join-Path $outDirR "update.merge.config")    -Encoding Default;
    $($checktypes| Select-Object @{Name="Out";Expression={"$($_.MergeConfig.Update)"}}      | %{$_.Out})  | Out-File $(Join-Path $outDirm "update.merge.config")    -Encoding Default;

    $($checktypes| Select-Object @{Name="Out";Expression={"$($_.RollbackConfig.Delete)"}}   | %{$_.Out})  | Out-File $(Join-Path $outDirR "delete.merge.config")    -Encoding Default;
    $($checktypes| Select-Object @{Name="Out";Expression={"$($_.MergeConfig.Delete)"}}      | %{$_.Out})  | Out-File $(Join-Path $outDirm "delete.merge.config")    -Encoding Default;

    # Summary Report
    $sbSummary                  = New-Object System.Text.StringBuilder;
    Append-ToSBList $sbSummary "Below are the changes found between the source ($($connSrc.Server)) and destination ($($connDst.Server))";
    Append-ToSBList $sbSummary "----------------------------------------------------------------------------------------------------------------";
    Append-ToSBList $sbSummary "";
    $listChanges.Keys | %{
        $key0 = $_;
        Append-ToSBList $sbSummary "$key0";
        Append-ToSBList $sbSummary "----------------------------------------------";
        $listChanges[$key0].Keys | % {
            $key1 = $_;
            Append-ToSBList $sbSummary "  $key1";
            $listChanges[$key0][$key1] | %{
                Append-ToSBList $sbSummary "    $_";
            }
        }
    }
    "$sbSummary"                | Out-File $(Join-Path $outDir "Summary.Report.log") -Encoding Default;
    
    # Summary Report (CSV)
    $sbSummaryCsv               = New-Object System.Text.StringBuilder;
    Append-ToSBList $sbSummaryCsv "Change Type,Module,Name";
    $listChanges.Keys | %{
        $key0 = $_;
        $listChanges[$key0].Keys | % {
            $key1 = $_;
            $listChanges[$key0][$key1] | %{
                Append-ToSBList $sbSummaryCsv "$key0,$key1,$_";
            }
        }
    }
    "$sbSummaryCsv"             | Out-File $(Join-Path $outDir "Summary.Report.csv") -Encoding Default;
    
    Pop-Location;

    #endregion

    Write-Host "Sync log output saved to: '$outDir'";
    Invoke-Item $outDir;
        
    Pop-Location; # Should pop off the PUTTY dir
        
    # Return the output dir to the user
    return $config;

    Write-Host "Options for updating destination device:" -ForegroundColor Yellow;
    Write-Host "  tmsh load sys config verify merge file XXX.YYY" -ForegroundColor Yellow;
    Write-Host "  tmsh load sys config from-terminal merge verify" -ForegroundColor Yellow;
}