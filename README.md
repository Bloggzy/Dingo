# Dingo

A self-contained, state-aware PowerShell/WPF utility for applying a repeatable set of Windows 11 VM preferences.

## Run it

1. Copy the entire Dingo folder to the VM.
2. Double-click Start-Dingo.cmd.
   Do not use **Run as administrator**. Dingo keeps its main window in your signed-in account and asks for administrator credentials later, only when needed.
3. Choose the **My account**, **Whole computer**, or **My account + whole computer** tab.
4. Each card explains the normal Windows choice, the current choice, and the available choices in plain language.
5. Tick the cards to change, or use **Choose all my preferred settings**.
6. Choose **Apply checked changes**. Windows requests administrator approval when the selection includes a whole-computer setting or a protected account policy marked **Admin approval required**.

No installation or PowerShell modules are required. Windows PowerShell 5.1 is included with Windows 11.

## Quick apply without the GUI

Use the same launcher with `-ApplyPreferred` to apply all 26 preferred settings without opening the selection window:

```bat
Start-Dingo.cmd -ApplyPreferred
```

The examples use the launcher so errors remain visible when it is double-clicked. From an existing PowerShell console, you can use `./Dingo.ps1` in place of `Start-Dingo.cmd`.

Dingo still runs as the signed-in user and displays a Windows administrator prompt when the plan contains protected or whole-computer settings. Do not run the launcher or script from an elevated console. Preview the plan without changing anything with:

```bat
Start-Dingo.cmd -WhatIf
```

Limit the plan by stable setting ID, using either repeated values or a comma-separated list:

```bat
Start-Dingo.cmd -ApplyPreferred -Include widgets,taskbar-search
Start-Dingo.cmd -WhatIf -Exclude language-au,windows-update-continuity
```

Add `-NoRestartExplorer` to suppress the automatic File Explorer restart. Exit code `0` means the plan succeeded (or a dry run completed), `1` means at least one setting failed or was only partially applied, `2` means the command or environment was invalid, and `3` means Dingo was already running.

An unrecognised option or stray positional argument is rejected with exit code `2` and the full help text is displayed; Dingo will not fall through to launching the GUI. The launcher preserves Dingo's exit code after displaying its pause prompt.

For automation, add `-OutputFormat Json` to `-WhatIf`, `-ApplyPreferred`, or `-ListSettings`. Discovery and help commands are:

```bat
Start-Dingo.cmd -ListSettings
Start-Dingo.cmd -ListSettings -OutputFormat Json
Start-Dingo.cmd -Version
Start-Dingo.cmd -Help
```

`-h` and `-?` are short aliases for `-Help`.

## Behaviour and safety

- Every item is applied independently and verified before it is marked successful.
- Current-state reads distinguish preferred, alternate, partial, unavailable, and error states. A read error is never treated as a missing setting, and **Check only settings that need changing** leaves unreadable settings unchecked.
- Application results track the user, protected-user, computer-wide, and final-verification components separately, so a mixed setting can be reported as partially applied instead of as an undifferentiated failure.
- The GUI stays in the signed-in desktop account, so per-user settings affect the correct Windows profile even when separate administrator credentials are needed. Protected per-user policy values are written by the elevated helper directly to that desktop user's SID, not to the administrator's profile.
- Twenty-one settings offer plainly labelled reversible choices. The five one-way targets—UTC, Australian region, Australian language, ISO date/time formats, and Widgets removal—can be left alone by unticking their cards.
- **Read settings again** rereads every configured value without making changes.
- Preflight is all-or-nothing: an unsupported plan is stopped before any changes. Once application begins, an individual setting failure does not stop later selected settings from running.
- Logs are written to the Logs folder beside the script (C:\DFIR\Tools\Dingo\Logs when run from the development directory) and can be opened from the GUI.
- Dingo permits only one normal GUI or quick-apply run per Windows account, preventing concurrent settings and result-file races. Read-only help, version, catalog, and internal self-test commands do not take the instance lock.
- GUI and quick-apply modes use the same setting executor, administrator broker, verification, structured results, and logs.
- Before applying a plan, Dingo checks every selected setting's handler, required Windows commands, readable current state, and declared edition/build requirements. If any preflight check fails, the plan is stopped before changes or administrator approval begin.
- Setting types are registered in an internal handler catalog that owns their scope, state reader, apply function, and prerequisites. This keeps the single-file distribution while providing an extension point for future file-association and application-management handlers.
- The window stays open while an administrator operation is active so Dingo can collect its results, verify changes, and remove temporary protocol files. Abandoned protocol files older than 24 hours are removed on a later launch.
- The tool is idempotent: rerunning it writes and verifies the same desired values.
- OneDrive is disabled with policy. It is not uninstalled, and user files are not deleted.
- Windows Widgets is removed only from the signed-in account. Dingo stops that account's Widgets processes, uninstalls `Microsoft.WidgetsPlatformRuntime` and `MicrosoftWindows.Client.WebExperience`, and verifies the result using that same account's live AppX package state. Other profiles are left unchanged, and Dingo does not provide a reinstall action.
- The Windows Copilot setting also removes Copilot shortcuts that Windows exposes in the signed-in user's standard taskbar pin folder; it does not uninstall Copilot apps.
- Windows Terminal's settings.json is serialized and validated before it atomically replaces the live file. Every change creates a uniquely named backup.
- Showing protected operating-system files is intentionally marked with a caution.
- On Windows 11 Pro, Enterprise, or Education, the optional **Forensic continuity: manual updates and restarts** policy prevents Windows Update from automatically downloading or installing updates, disables update deadline enforcement, blocks update-driven restarts while a user is signed in, and suppresses all Windows Update notifications. This trades automatic patching for uninterrupted evidence processing: operators must check, install, and restart during a controlled maintenance window.

## Important limitations

- Microsoft now ships Copilot in several forms. The Windows setting applies the legacy Windows Copilot policy and hides integrated UI, but does not uninstall the newer standalone app. Microsoft recommends AppLocker or managed uninstall policy for centrally blocking that app.
- Some Edge policies, especially the default search provider, may only be enforced on a domain-joined or device-managed instance. The tool verifies that policy values were written; visit edge://policy after restarting Edge to confirm Edge accepted them.
- Removing the entire Recommended section is edition/build dependent. The tool disables recent and suggested content and applies the section-hiding policy where available.
- Microsoft does not ship a standalone full display pack for English (Australia). Windows exposes **English (Australia)** as a selectable interface language once the British English (`en-GB`) base resources are installed. Dingo installs that underlying display pack when needed, then selects `en-AU` for the Windows interface, input, spelling, regional formats, and system locale. Windows applies and reports the requested UI language after sign-out or restart.
- While a language pack is downloading, Dingo keeps its window responsive, shows the elapsed time in the status area, and records an installation heartbeat in the log every 30 seconds. Other controls remain disabled until the administrator step finishes so that settings cannot be applied twice concurrently.
- Dingo isolates its WPF interface from elevation operations by delegating administrator approval to a separate non-WPF broker process. It avoids fragile `Shell.Application` enumeration during state scans; Copilot policies and ordinary taskbar shortcuts are handled directly, while an opaque packaged-app pin may need to be unpinned manually.
- When a language-profile change is pending, Dingo registers a one-time sign-in finalizer for its ISO date/time preference. This reapplies the custom formats after Windows finishes initialising the new language, preventing Windows from replacing them with the locale defaults.
- Long-path, OneDrive, and Copilot changes can require a restart.
- The forensic-continuity policy cannot cancel an update restart that was already pending when it was applied. Choose **Another time**, apply the policy, and perform the pending restart manually when evidence processing is safely stopped. Domain, Intune/MDM, or other management policy can reapply conflicting update settings; verify Dingo still reports the protected state before starting a long-running acquisition or processing job.
- Windows Terminal must have been launched at least once so its settings file exists.

## Settings included

- UTC, Australian region and Australian English, plus yyyy-MM-dd and 24-hour time formats
- Taskbar Search, Task View, current-account Widgets package removal, detectable Copilot shortcut removal, Resume, never-combine, and right-click End task
- Explorer This PC, hidden files, extensions, protected files, navigation expansion, and long paths
- OneDrive sync and Windows Copilot policies
- Forensic-continuity control for manual Windows Update installation/restarts and suppressed update notifications
- Edge first-run/import controls, password manager, Copilot surfaces, and DuckDuckGo search
- Windows PowerShell parent-process directory in Windows Terminal
- Start-menu Bing/web search and recommendations

## Research basis

The implementation uses Microsoft policy/settings documentation and selected ideas from Chris Titus Tech's WinUtil. WinUtil is a reference only; this project does not bundle or execute WinUtil.
