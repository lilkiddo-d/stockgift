# Direct mainnet deploy, no menus. Run from the repo root:
#   powershell -ExecutionPolicy Bypass -File scripts\deploy-direct.ps1
# Foundry asks for the stockgift-deployer keystore password. Deployer = Timelock proposer = guardian
# (override by setting $env:TIMELOCK_PROPOSER / $env:GUARDIAN before running).
$ErrorActionPreference = "Stop"
$Deployer = "0x00C7DB7dc6d7879c893A3c92c3c2625e99D84B0E"
Set-Location (Join-Path (Split-Path -Parent $PSScriptRoot) "contracts")
Remove-Item Env:WRITE_DEPLOYMENT, Env:WRITE_FRONTEND -ErrorAction SilentlyContinue

forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com `
  --account stockgift-deployer --sender $Deployer --broadcast --slow `
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/

if (Test-Path "deployments/4663.json") {
  Set-Location ..
  git add contracts/deployments/4663.json app/src/config/generated/deployment.json
  git commit -m "Deploy Stockgift to Robinhood Chain mainnet"
  git push
  Get-Content contracts/deployments/4663.json
} else {
  Write-Host "No deployments/4663.json - deploy did not complete, see output above."
}
