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
| P4-F04 | Installer timeout | Start with a harmless purpose-built waiting installer in a separate test catalog, not a real evidence-processing tool. Verify parent/child exit and partial/unknown wording. |
| P4-F05 | Interrupt Dingo during a controlled harmless operation | Preserve journals. Run `Start-Dingo.cmd -RecoveryReport -OutputFormat Json`; missing completion is unknown, never replayed. Check whether any installer process remains active before retry. |
| P4-F06 | Denied write during a controlled multi-entry operation | Earlier successful writes remain reported; later skipped entries are visible. Do not change permissions on production policy keys just to provoke failure. Use a reviewed disposable fixture. |

The reviewed fault fixtures and procedures appear below; do not improvise disruptive failures. Separate administrator credentials are optional compatibility coverage, not a requirement for this deployment model.

### Reviewed P4-F02 fixture

`Fixtures\P4-F02.Tools.json` adds one per-user script tool whose detection marker is deliberately absent. Its URL points to this project's public README, while its deliberately impossible all-zero SHA256 prevents downloaded content from executing if the network is accidentally left connected. The expected disconnected-network failure therefore occurs during `Invoke-WebRequest`, before Dingo creates the destination or starts an installer. Dingo's download timeout is 120 seconds.

Use a disposable snapshot and confirm that neither `Tools.json` nor `C:\Temp\Dingo-P4-F02-installed.marker` exists before setup. Copy the fixture to `Tools.json`, collect before evidence, disconnect the guest network, and apply only `tool-p4-f02-network`. Expect no UAC, process exit code 1, one failed result that names the download/network error, and a final state of Partial / Not installed. The marker and destination must remain absent. Reconnect the network before collecting after evidence and reading the log; do not retry while `Tools.json` is present. Restore the snapshot afterward.

### Reviewed P4-F03 setup

Use a disposable snapshot with the normal built-in catalog and a complete EZTools installation. Move `C:\DFIR\Tools\EZTools\net9\EvtxECmd\EvtxECmd.exe` to a backup path under `C:\Temp`; do not delete it or remove the .NET runtime. Collect evidence and preview only `tool-eztools`. Expect no UAC and preview exit code 0: the tool must read Partial / Incomplete installation, with three of four required files detected and the EvtxECmd path named as missing. Do not apply the tool card, because doing so would invoke the real upstream installer. Copy the evidence out and restore the snapshot afterward.

### Prepared P4-F04 fixture

`Fixtures\P4-F04-Wait.ps1` starts one hidden child PowerShell process, records its process ID in `%TEMP%\Dingo-P4-F04-child-pid.txt`, and waits for five minutes. It makes no system or application changes. `Fixtures\P4-F04.Tools.json` configures it as a per-user script tool with a one-minute execution timeout and pins the exact script SHA256. The install destination may be created before execution, but the deliberately absent detection marker must remain absent.

The waiting script is published on the active test branch in commit `b381781`. A fresh download from the catalog URL matched the pinned SHA256 `6B301336B24F7B6734E6BF1936FFADF7C27BEB6E10FF75E72A291906D78CD4EA` exactly and parsed without errors. The expected result is no UAC, CLI exit code 1, one failed tool result that says the install script timed out after 60 seconds and may be partial, an absent detection marker, and no surviving process with the recorded child PID. Preserve the Dingo log and journal for recovery-report inspection before restoring the snapshot.

### Reviewed P4-F05 fixture

`Fixtures\P4-F05.Tools.json` reuses the published, hash-pinned waiting script with a five-minute timeout and a separate absent detection marker. Start Dingo as a child process with output redirected, wait until the fixture records its sleeping child PID, identify the intermediate installer process, and then force-stop only the top-level Dingo process. Windows Job Object closure should terminate the installer and sleeper. The journal must retain a Started record without a Completed record, so `-RecoveryReport` must return one `Completion unknown` entry for `tool-p4-f05-interruption` without replaying it. The destination may exist; the detection marker must remain absent and every captured process ID must be stopped. Restore the disposable snapshot after preserving evidence.

### Reviewed P4-F06 fixture

`Fixtures\P4-F06-DeniedWrite.ps1` imports Dingo's production functions without running its startup path, creates three disposable values below `HKCU\Software\Dingo\Phase4\P4-F06`, and denies only `SetValue` on the middle fixture key for the current account. The fixture uses the .NET registry API for ACL and cleanup operations because the Windows PowerShell 5.1 registry provider does not reliably resolve ACL paths on the test image; Dingo's production registry handler remains the code under test. It invokes that handler in order. The first write must succeed and change 0 to 1, the denied write must fail and remain 0, and the third must be reported Skipped / NotAttempted and remain 0. Dingo's result must be PartiallyApplied with all three entry outcomes preserved. In a `finally` block, the harness explicitly removes the exact deny rule it added through its retained registry handle, opens the immediate fixture parent, deletes only its `P4-F06` child, and verifies absence through a fresh .NET lookup. No production policy path or machine-wide permission is touched. Run it non-elevated on a disposable snapshot and preserve its result, log, and journal.

## Exit criteria

Every case has pass/fail/blocked/not-run with evidence and a snapshot reference. Findings have reproduction steps; code fixes receive regression checks and an affected-case VM retest. Finish with an end-to-end pass from a known snapshot. Record unsupported cases and unverified behavior explicitly. The current test subject is 0.6.8, including wildcard detection, association write ordering, Explorer FileExts cleanup, native association command paths, retired Edge-policy cleanup, and unobscured actionable sign-out/restart guidance found during VM validation. No Phase 4 pass is claimed merely because the test pack exists.
