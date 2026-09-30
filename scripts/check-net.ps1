$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } | Select-Object -First 3)
foreach ($i in $ip) { Write-Output ("IP: " + $i.IPAddress + "  if=" + $i.InterfaceAlias) }
$l = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
if ($l) { foreach ($c in $l) { $p = (Get-Process -Id $c.OwningProcess).Path; Write-Output ("LISTEN 8080 pid=" + $c.OwningProcess + " exe=" + $p) } } else { Write-Output "NOT-LISTENING 8080" }
