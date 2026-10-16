# 一键构建并推送到 Gitee + GitHub
$ErrorActionPreference = "Continue"

Write-Host "==> 构建 MkDocs..." -ForegroundColor Cyan
& E:\src\mkdocs-env\Scripts\mkdocs.exe build --site-dir E:\src\dev-vault\docs
if ($LASTEXITCODE -ne 0) { Write-Host "构建失败" -ForegroundColor Red; exit 1 }

Set-Location E:\src\dev-vault
git add -A
git commit -m "update: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 2>&1 | Out-Null

Write-Host "==> 推送 Gitee..." -ForegroundColor Cyan
git push origin master 2>&1

Write-Host "==> 推送 GitHub（重试3次）..." -ForegroundColor Cyan
$ok = $false
for ($i = 1; $i -le 3; $i++) {
    git push github master 2>&1
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    Write-Host "  第${i}次失败，5秒后重试..." -ForegroundColor Yellow
    Start-Sleep 5
}
if ($ok) { Write-Host "GitHub推送成功" -ForegroundColor Green }
else { Write-Host "GitHub推送失败（网络问题，稍后手动 git push github master）" -ForegroundColor Yellow }

Write-Host "`n完成。等1-2分钟访问 https://liucl-001.github.io/DevVault/" -ForegroundColor Green
