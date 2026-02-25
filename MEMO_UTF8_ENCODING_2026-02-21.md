# UTF-8 Mitigation Memo (2026-02-21)

## What was changed
- Added `.editorconfig` with UTF-8 defaults:
  - `charset = utf-8`
  - `end_of_line = lf`
  - `insert_final_newline = true`
- Added UTF-8 defaults to PowerShell profile files:
  - `C:\Users\skyeu\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
  - `C:\Users\skyeu\OneDrive\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`

## Profile block
```powershell
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8'
$PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8'
```

## Validation
- Both profile files parse successfully (`PARSE_OK`).
- Existing terminal may still show profile-load warnings if execution policy blocks profile scripts.

## Quick check (new PowerShell session)
```powershell
[Console]::OutputEncoding.WebName
$PSDefaultParameterValues['Out-File:Encoding']
```
