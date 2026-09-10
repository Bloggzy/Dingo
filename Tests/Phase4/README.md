# Phase 4: Windows VM integration

Target: VMware Workstation 17.6.2 build-24409262; Windows 11 Pro 25H2 build 26200.9445. One administrator-capable account (`User` on this VM), normally running with a filtered token and using UAC consent. Existing preferred settings and installed tools are part of the baseline. Do not uninstall or reset them to manufacture a clean machine.

## First session: snapshot and baseline only

1. Shut down the guest normally. In VMware, take a snapshot named **Before Dingo Phase 4** and record it in RESULTS.md. Start the guest again.
2. Copy the entire Dingo folder into the guest, for example `C:\Tools\Dingo`. Include `Tests\Phase4`. Record any Tools.json override; do not copy old host Logs into the guest test folder.
3. Open **Windows PowerShell** normally inside the guest, without Run as administrator. Run:

```powershell
Set-Location C:\Tools\Dingo
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Phase4\Collect-Evidence.ps1 -Label baseline
```

The collector imports Dingo function definitions and calls state readers, without running Dingo startup or applying settings. Its only intentional writes are a uniquely named evidence folder under `Tests\Phase4\Evidence`. It records account/build details, Dingo's SHA256, state readings, uninstall inventory, PATH, and hashes of files in the shared Desktop and Dingo shortcut/launcher folders. Errors remain visible. It does not establish application launchability or effective policy. It is not a forensic acquisition tool; ordinary Windows activity and reads can leave OS traces.

4. Review `environment.json` and `settings-summary.csv`. Confirm build/account and `Elevated: false`. Note already-preferred settings and existing software. Keep the full evidence directory. Share those two files first for baseline review; evidence contains account names and paths, so review it before sharing beyond this test.
5. Stop here until the baseline is reviewed. Do not choose Apply all yet.

## Evidence discipline

Copy RESULTS.md into the evidence root as your working results file. Record actual observations, not just green cards. After each case run the collector again with a distinct label, such as `after-uac-cancel`. Preserve Dingo's Logs (including journal files), screenshots of relevant cards/dialogs, CLI output, and tool versions. Copy evidence out of the guest before restoring a snapshot, or the restore will discard it. A skipped or blocked case is not a pass.

Preview commands create/rotate Dingo logs even though they do not apply preferences. Keep baseline capture separate from preview. The standalone collector does not rotate those logs.

## Normal-path cases

| ID | Action | Acceptance and evidence |
| --- | --- | --- |
| P4-01 | Baseline collector, then open Dingo normally | Account/build agree. Main process is not elevated. All cards load; unreadable states are explicit. Existing software is detected. |
| P4-02 | Run `Start-Dingo.cmd -WhatIf -OutputFormat Json` | Preview only; settings/installed-tool inventory match baseline afterward. Preferred tool action is Installed, never implicit Update. Record proposed plan. |
| P4-03 | Choose one reversible account setting currently not preferred; apply it | Only requested values change. Current account is User. Confirm observable behavior, allowing an Explorer restart where indicated. If all are preferred, use an alternate choice on a reversible card and record that setup. |
| P4-04 | Choose one reversible machine setting; cancel UAC | No machine mutation. UI unlocks. Result says failure/cancellation rather than success. Avoid a mixed user/machine card for this case. |
| P4-05 | Repeat P4-04 and approve UAC | Machine change succeeds and reads back. Account identity remains correct. Repeat the same choice; results remain accurate and no unrelated changes appear. |
| P4-06 | Apply Installed to existing 7-Zip/Notepad++ | Existing versions remain unchanged; no installer runs. Check logs and uninstall inventory. An automatic external update makes the case inconclusive until isolated. |
| P4-07 | Select a genuinely missing tool, then its supported shortcuts/PATH | Install succeeds, detection is accurate, tool launches on harmless sample data. Validate shortcuts and command resolution in a new shell. Test EZTools plus .NET prerequisite if missing. |
| P4-08 | Explicit Update installed tool on a snapshot branch | Installer/update dispatch is explicit. A no-update result is acceptable when current. Record versions and logs; no uninstall expected. |
| P4-09 | Configure associations with a target installed | Test an extension without protected UserChoice and another with an existing Windows choice. Confirm default vs Open with wording and actual opening of harmless sample files. Do not use evidence originals. |
| P4-10 | Reverse association choices | Previous extension choice is restored where supported. If UserChoice references Dingo, reversal instructs selection of another default in Windows Settings and keeps a working handler. Retest after changing it in Settings. |
| P4-11 | Apply the same small selection via CLI on a restored branch | Compare against GUI result from the same initial snapshot. Preserve JSON and `$LASTEXITCODE`; no launcher pause in direct PowerShell invocation. Example: `& .\Dingo.ps1 -ApplyPreferred -Include <tested-ids> -OutputFormat Json`. Replace placeholder with actual IDs from baseline. |
| P4-12 | Broader preferred selection, then sign-out/reboot where required | Review intended changes first, especially update notifications, language, timezone and Widgets removal. Verify actual UI/application behavior after restart separately from registry state. Export Edge policy evidence; do not infer restart prevention from a configured update card. |

Capture a new snapshot after normal-path validation if helpful, but retain the original baseline snapshot. Restore the original for comparisons that require identical starting state.

## Failure/recovery branches

Run these individually from snapshots, after normal-path cases. Prepare each fault and document it before applying anything.

| ID | Fault/setup | Acceptance |
| --- | --- | --- |
| P4-F01 | An unmarked same-name shortcut or launcher on a test branch | Preflight/write refusal; original file hash unchanged. Restore snapshot afterward. |
| P4-F02 | Temporarily disconnect guest network during a selected missing-tool download | Failure/timeout is bounded and explicit. A partial install is not reported as fully installed. Reconnect before diagnosis/retry. |
| P4-F03 | A missing EZTools component or prerequisite on a disposable branch | Partial inventory/dependency state appears. Do not remove an installed runtime from the baseline branch. Use a separate clone if needed. |
| P4-F04 | Installer timeout | Start with a harmless purpose-built waiting installer in a separate test catalog, not a real evidence-processing tool. Verify parent/child exit and partial/unknown wording. Keep this case pending until the fixture and catalog are reviewed. |
| P4-F05 | Interrupt Dingo during a controlled harmless operation | Preserve journals. Run `Start-Dingo.cmd -RecoveryReport -OutputFormat Json`; missing completion is unknown, never replayed. Check whether the elevated worker remains active before retry. Keep pending until an interruption fixture is reviewed. |
| P4-F06 | Denied write during a controlled multi-entry operation | Earlier successful writes remain reported; later skipped entries are visible. Do not change permissions on production policy keys just to provoke failure. Use a reviewed disposable fixture. |

Fault fixtures for P4-F04 through P4-F06 are a later preparation step; do not improvise disruptive failures. Separate administrator credentials are optional compatibility coverage, not a requirement for this deployment model.

## Exit criteria

Every case has pass/fail/blocked/not-run with evidence and a snapshot reference. Findings have reproduction steps; code fixes receive regression checks and an affected-case VM retest. Finish with an end-to-end pass from a known snapshot. Record unsupported cases and unverified behavior explicitly. The current test subject is 0.6.5, including wildcard-detection, association write-order, and Explorer FileExts cleanup fixes found during VM validation. No Phase 4 pass is claimed merely because the test pack exists.
