Param(
    [Parameter(Mandatory=$true)]
    [string]$username,
    [Parameter(Mandatory=$true)]
    [string]$password
)

Add-Type -AssemblyName System.DirectoryServices.AccountManagement

$ctx_type = [System.DirectoryServices.AccountManagement.ContextType]::Machine

if ($username -match '@') {
    $ctx_type = [System.DirectoryServices.AccountManagement.ContextType]::Domain
}

$DSContext = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
    $ctx_type
)

if ( $DSContext.ValidateCredentials( $username, $password ) ) {
    exit 0
} else {
    exit 1
}
