param([int]$ParentPid,[string]$Archive,[string]$Target,[string]$Executable,[string]$Version)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $Archive
$Stage=Join-Path $Root 'expanded'
$Backup=$Target+'.littlepets-backup'
$Moved=$false
try {
 Expand-Archive -LiteralPath $Archive -DestinationPath $Stage -Force
 $New=Join-Path $Stage 'app'
 $Meta=Get-Content -LiteralPath (Join-Path $New 'package.json') -Raw | ConvertFrom-Json
 if($Meta.name -ne 'little-companions' -or $Meta.version -ne $Version){throw 'Update package identity mismatch'}
 $P=Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
 if($P){if(-not $P.WaitForExit(60000)){throw 'Application did not exit'}}
 $Done=$false
 for($Retry=0;$Retry -lt 10;$Retry++) {
  try {
   if(Test-Path -LiteralPath $Backup){Remove-Item -LiteralPath $Backup -Recurse -Force}
   Move-Item -LiteralPath $Target -Destination $Backup
   $Moved=$true
   Move-Item -LiteralPath $New -Destination $Target
   $Done=$true;break
  } catch {
   if($Moved -and -not(Test-Path -LiteralPath $Target)){Move-Item -LiteralPath $Backup -Destination $Target;$Moved=$false}
   Start-Sleep -Seconds 1
  }
 }
 if(-not $Done){throw 'Unable to replace application'}
 Start-Process -FilePath $Executable
 Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
} catch {
 if($Moved -and -not(Test-Path -LiteralPath $Target)){Move-Item -LiteralPath $Backup -Destination $Target}
 $_.Exception.Message | Set-Content -LiteralPath (Join-Path $Root 'update-error.txt')
 if(Test-Path -LiteralPath $Executable){Start-Process -FilePath $Executable}
}
