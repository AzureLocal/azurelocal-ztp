# Commands

<!-- How to build, test, and run THIS specific repo. Exact commands, not generalities. -->

```powershell
# Pester 5 tests for the simplified-provisioning scripts (no hardware, no Azure; mocks only)
Invoke-Pester ./tests/simplified-provisioning

# PSScriptAnalyzer (Error + Warning, default rules)
Invoke-ScriptAnalyzer -Path ./scripts/simplified-provisioning -Recurse -Severity Error, Warning
Invoke-ScriptAnalyzer -Path ./tests/simplified-provisioning -Recurse -Severity Error, Warning

# Bicep template build (local only)
az bicep build --file ./scripts/simplified-provisioning/bicep/main.bicep --stdout

# Docs (VitePress)
cd docs; npm install; npm run docs:build
```
