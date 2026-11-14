# Integration Tests

See `TEST-PLAN.md` for the 15-test checklist.

## Quick run (owner's machine)

```powershell
# On Windows (admin):
Invoke-Pester tests/powershell -Output Detailed
Verify-Installation.ps1

# On Mac:
node --test tests/cloud/function.test.js
bash mac/connect.sh --test
```

## What needs real hardware

| Test group | Needs |
|------------|-------|
| 1–6,12–14 | Windows 10+ admin VM or physical |
| 7–9 | Yandex VM + Windows |
| 10–11 | Yandex Function + API Gateway |
| 3,8,15 | Manual reboot / network interruption |

Mark results in `TEST-PLAN.md` only after real execution.
