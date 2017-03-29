function Get-F5VipsAndSslProfiles($f5HostIp, $f5Cred, [switch]$IgnoreCertErrors = $false) {
    $f5Host = "https://$f5HostIp/mgmt/tm";

    if ($IgnoreCertErrors) {
        Add-Type @"
            using System.Net;
            using System.Security.Cryptography.X509Certificates;
            public class TrustAllCertsPolicy : ICertificatePolicy {
                public bool CheckValidationResult(
                    ServicePoint srvPoint, X509Certificate certificate,
                    WebRequest request, int certificateProblem) {
                    return true;
                }
            }
"@;
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy;
    }

    $sslProfilesClient = $(Invoke-RESTMethod -Method GET -Uri "$($f5Host)/ltm/profile/client-ssl?`$select=name,partition,fullPath" -Credential $f5Cred).items | Select-Object -ExpandProperty FullPath;
    $sslProfilesServer = $(Invoke-RESTMethod -Method GET -Uri "$($f5Host)/ltm/profile/server-ssl?`$select=name,partition,fullPath" -Credential $f5Cred).items | Select-Object -ExpandProperty FullPath;
    $virtualServers    = $(Invoke-RESTMethod -Method GET -Uri "$($f5Host)/ltm/virtual?expandSubcollections=true&`$select=name,partitioclsn,fullPath,profilesReference" -Credential $f5Cred);

    $virtualServers.items | Select-Object Name, FullPath, `
                                    @{Name="ClientSslProfiles"; Expression={($_.profilesReference.items | ?{ $sslProfilesClient -contains $_.fullPath -and $_.context -eq "clientside" }) | Select -ExpandProperty fullPath }}, `
                                    @{Name="ServerSslProfiles"; Expression={($_.profilesReference.items | ?{ $sslProfilesServer -contains $_.fullPath -and $_.context -eq "serverside" }) | Select -ExpandProperty fullPath }};
}

$cred = $(Get-Credential);
Get-F5VipsAndSslProfiles "x.x.x.x" $cred;
