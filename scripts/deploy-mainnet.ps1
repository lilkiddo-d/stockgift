# Stockgift mainnet deploy (Windows PowerShell).
# Usage, from the repo root:   powershell -ExecutionPolicy Bypass -File scripts\deploy-mainnet.ps1
# Signs only with the Foundry keystore "stockgift-deployer"; Foundry asks for its password itself.

$ErrorActionPreference = "Stop"
$Rpc = "https://rpc.mainnet.chain.robinhood.com"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location (Join-Path $Root "contracts")

function Ask-Address($prompt, $default) {
  $v = Read-Host "$prompt [default: $default]"
  if ([string]::IsNullOrWhiteSpace($v)) { return $default }
  if ($v -notmatch '^0x[0-9a-fA-F]{40}$') { throw "Not an address: $v" }
  return $v
}

# 1. deployer address
$Deployer = $null
try { $Deployer = (& cast wallet address --account stockgift-deployer).Trim() } catch {}
if (-not $Deployer -or $Deployer -notmatch '^0x[0-9a-fA-F]{40}$') {
  Write-Host "Could not read the address with cast (it may be blocked by Windows Application Control)."
  $Deployer = Read-Host "Paste the stockgift-deployer address (0x...)"
  if ($Deployer -notmatch '^0x[0-9a-fA-F]{40}$') { throw "Not an address: $Deployer" }
}
Write-Host "Deployer: $Deployer"

# 2. admin roles (multisigs strongly recommended)
$env:TIMELOCK_PROPOSER = Ask-Address "Timelock proposer/executor (Safe multisig recommended)" $Deployer
$env:GUARDIAN = Ask-Address "Guardian: pause/unpause + allowlist (multisig recommended)" $Deployer

# 3. dry run (sends nothing)
Write-Host "`n=== Dry run against live mainnet (nothing is sent) ==="
$env:WRITE_DEPLOYMENT = "false"; $env:WRITE_FRONTEND = "false"
& forge script script/Deploy.s.sol --rpc-url $Rpc --account stockgift-deployer --sender $Deployer
if ($LASTEXITCODE -ne 0) { throw "Dry run failed - nothing was deployed." }
Remove-Item Env:WRITE_DEPLOYMENT, Env:WRITE_FRONTEND

$go = Read-Host "`nDry run OK. Type DEPLOY to broadcast to Robinhood Chain mainnet"
if ($go -ne "DEPLOY") { Write-Host "Aborted. Nothing was sent."; exit 0 }

# 4. broadcast + verify
& forge script script/Deploy.s.sol --rpc-url $Rpc --account stockgift-deployer --sender $Deployer `
  --broadcast --slow --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
$deployExit = $LASTEXITCODE
if (-not (Test-Path "deployments/4663.json")) { throw "Deployment file not written - check the output above." }
if ($deployExit -ne 0) {
  Write-Host "Contracts deployed, but a later step (likely Blockscout verification) failed."
  Write-Host "Re-verify with: forge script script/Deploy.s.sol --rpc-url $Rpc --account stockgift-deployer --sender $Deployer --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/"
}

# 5. commit + push addresses so the app uses them
Set-Location $Root
git add contracts/deployments/4663.json app/src/config/generated/deployment.json
git commit -m "Deploy Stockgift to Robinhood Chain mainnet"
git push
Write-Host "`nDone. Addresses: contracts/deployments/4663.json"
Get-Content contracts/deployments/4663.json
