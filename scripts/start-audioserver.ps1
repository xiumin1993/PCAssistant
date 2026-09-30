Start-Process -FilePath "D:\code\AudioServer\target\release\audioserver.exe" -WorkingDirectory "D:\code\AudioServer\target\release"
Start-Sleep -Seconds 4
$l = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
if ($l) { Write-Output "LISTENING 8080" } else { Write-Output "NOT-LISTENING 8080" }
