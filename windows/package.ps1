param(
    [Parameter(Mandatory)][string]$PublishDir,
    [Parameter(Mandatory)][string]$OutputDir,
    [Parameter(Mandatory)][string]$Compiler
)
$ErrorActionPreference = 'Stop'
$published = (Resolve-Path -LiteralPath $PublishDir).Path
if (-not (Test-Path -LiteralPath (Join-Path $published 'BonfireCore.dll'))) { throw 'Missing native transfer library.' }
$destination = [IO.Directory]::CreateDirectory($OutputDir).FullName
$version = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../VERSION')).Trim()
& $Compiler "/DPublishDir=$published" "/DOutputDir=$destination" "/DReleaseVersion=$version" (Join-Path $PSScriptRoot 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }
$zip = Join-Path $destination "Bonfire-$version-Windows-x64-Portable.zip"
# bsdtar includes the runtime's hidden files and retains the publication layout.
& tar.exe -a -c -f $zip --exclude '*.pdb' -C $published .
if ($LASTEXITCODE -ne 0) { throw "Archive creation failed ($LASTEXITCODE)" }
