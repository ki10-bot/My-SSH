# RemoteGate — Windows 10 End of Support

## Summary

- **General support ended:** October 14, 2025 (Microsoft lifecycle: https://learn.microsoft.com/en-us/lifecycle/products/windows-10-home-and-pro)
- **Implication:** Home/Pro no longer receive free security updates or technical support.
- **Supported alternatives:** Windows 11, Windows Server 2019/2022/2025, Windows 10 Enterprise/ Education LTSC/IoT (extended timelines), ESU program.

## What this means for RemoteGate

RemoteGate **still works** on Windows 10 build 1809+ (17763+). The installer checks build and warns if ≥17763 but OS is unsupported. OpenSSH Server capability remains usable on eligible builds.

However, **we do not claim Windows 10 is secure post-2025-10-14** without mitigations.

## Recommendations

### 1. Preferred: Upgrade to Windows 11

- Check compatibility: `Settings > System > About` → System type, TPM 2.0, Secure Boot.
- Microsoft PC Health Check: https://aka.ms/GetPCHealthCheck
- Upgrade via Windows Update or clean install.
- After upgrade, OpenSSH reinstall is usually not needed (capability persists); re-verify with `Verify-Installation.ps1`.

### 2. Extended Security Updates (ESU)

Microsoft offers paid ESU for Windows 10 for up to 1–3 years (initially consumers $30~60/year, varies by channel).

- Details: https://learn.microsoft.com/en-us/windows/whats-new/extended-security-updates
- Enroll via Microsoft account / Volume Licensing.
- With ESU, you receive critical security patches — installer still warns, but you can document ESU enrollment in your config.

### 3. LTSC / IoT editions

- **Windows 10 Enterprise LTSC 2021:** Support until 2027-01-12
- **Windows 10 IoT Enterprise LTSC 2021:** Until 2032-01-13
- These are **special SKUs** — not consumer Home/Pro. If you have them, check `winver` edition name and lifecycle: https://learn.microsoft.com/en-us/lifecycle/products/windows-10-enterprise-ltsc

### 4. If you must stay on unsupported Windows 10

Treat as **lab/isolated** only:

- **Do not expose port 22 to Internet** (RemoteGate already restricts to LocalSubnet).
- **Use tunnel only** (outbound) — no public inbound.
- **Keep Windows Defender enabled** (RemoteGate does not disable it) + firewall on.
- **Minimize software**, uninstall unused apps, patch browsers/Office still supported.
- **Network isolate:** VLAN or guest WiFi that cannot reach internal assets.
- **Plan migration** — set calendar reminders for ESU expiry.

Note: OpenSSH Server on Windows 10 will not receive new features tied to newer Windows versions; upstream Win32-OpenSSH releases still run, but capability payload lags.

## PowerShell compatibility

| PowerShell | On Windows 10 | For RemoteGate |
|------------|---------------|----------------|
| 5.1 | Included, best for `Add-WindowsCapability` | Use 5.1 for install (even if PS 7 installed) |
| 7+ | Optional via MSI/Store | Fine as SSH DefaultShell (`C:Program Files\PowerShell\7\pwsh.exe`) but not for servicing |

RemoteGate supports both; installer uses 5.1.

## OpenSSH capability availability

| Windows version | OpenSSH Server source |
|-----------------|----------------------|
| Windows 10 1809+ (Home/Pro) | `OpenSSH.Server~~~~0.0.1.0` via Windows Update/FoD |
| Windows 11 | Same capability |
| Windows Server 2019/2022 | Same capability |
| Windows Server 2025 | Features on-demand, sshd present but not started |

If Windows Update is blocked (WSUS without FoD), use `-Source E:\Sources\SxS -LimitAccess` with Features on Demand media (enterprise). See https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/features-on-demand-v2--capabilities

## Firewall behavior

No change post-EOL — Windows Firewall rules persist. `OpenSSH-Server-In-TCP` still controls inbound. RemoteGate's `LocalSubnet` restriction remains effective.

## Installer behavior

- Build <17763 → **fail** (feature not available).
- Build ≥17763 → **warn** if OS version string indicates 10.0.1904x (Windows 10) and date >2025-10-14.
- Build ≥22000 (Windows 11) → no warning.
- Check `winver` or `Get-CimInstance Win32_OperatingSystem | select Caption,Version,BuildNumber`.

## FAQ

**Q: Can I still get security updates?**
A: Only via ESU or LTSC/IoT. Home/Pro without ESU get no patches — see Microsoft docs.

**Q: Will RemoteGate break when 10 expires?**
A: No — capability and sshd continue to function, but underlying OS vulns are your risk.

**Q: Should I use Windows 10 for new production SSH host?**
A: No — choose Windows 11 or supported Server. See https://support.microsoft.com/en-us/topic/windows-10-support-has-ended-on-october-14-2025-e0b5bb06-c7cc-4e96-8aae-5c3fd2fe6dcc

---

*Last updated: 2025-11. Verify latest lifecycle at Microsoft links above.*
