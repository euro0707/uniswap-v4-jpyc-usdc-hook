# Agent Workflow Notes

## Error Memory Loop (Required)

Before coding:
1. Fetch latest docs with context7 (MCP).
2. Build an error fingerprint when relevant:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\script\error-fingerprint.ps1 -Text "<task or error text>" -Output json`
3. Search past errors first:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\script\search-error-memory.ps1 -Query "<keyword>"`
4. Apply known prevention steps before making changes.

After fixing any error:
1. Record the incident immediately:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\script\add-error-memory.ps1 -Title "<title>" -ErrorMessage "<error>" -Cause "<cause>" -Fix "<fix>" -Learning "<learning>" -Fingerprint "<fingerprint>"`
2. Mark it resolved with minimal friction:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\script\resolve-error-memory.ps1 -Resolution "<one-line fix summary>"`
3. Keep one note per incident and include a concrete prevention rule.

## Storage Path
- Primary: `C:\Users\skyeu\obsidian\TetsuyaSynapse\90-Claude\reflections\build`
- If unavailable temporarily, log in this repo and sync later.
