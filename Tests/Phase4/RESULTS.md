# Phase 4 results

Status: Paused after successful 0.6.5 association-reversal retest. Resume with the remaining normal-path and failure/recovery cases below.

- Hypervisor: VMware Workstation 17.6.2 build-24409262
- Guest: Windows 11 Pro 25H2, expected build 26200.9445
- Account model: one administrator-capable user, normal launch with UAC consent
- VM name / snapshot name and timestamp:
- Dingo version / script SHA256:
- Tools.json present / hash:
- Baseline evidence folder:
- Existing preferred settings and installed tools:

For each case copy this block. Use Pass, Fail, Blocked, or Not run.

## Case ID / title

- Status:
- Starting snapshot:
- Prerequisites / deliberate setup changes:
- Exact selection or command:
- Expected result:
- Observed result / elapsed time / exit code:
- Account and UAC behavior:
- Before and after evidence folders:
- Logs, journal, screenshots and application behavior:
- Unexpected changes:
- Finding / reproduction steps:
- Fix / retest result:

## Coverage and release decision

- Cases passed: P4-01 through P4-06; P4-07a (ripgrep user-scope install); P4-09; P4-10; single-instance guard.
- Cases failed: No unresolved failures. Findings in P4-09a and P4-10a were corrected in 0.6.4 and 0.6.5 respectively and passed targeted VM retests.
- Cases blocked or not run, with reasons: Remaining P4-07 coverage for EZTools, prerequisites, shortcuts and PATH; P4-08; P4-11; P4-12; P4-F01 through P4-F06. Work paused at the operator's request before these cases.
- Effective behavior verified after sign-out/reboot:
- Remaining limitations: No full end-to-end run from the original snapshot yet. Update-policy effectiveness, machine restart/sign-in behavior, EZTools installation, explicit updates, shortcut/PATH behavior, CLI comparison, and prepared failure/recovery branches remain unverified.
- Final end-to-end snapshot and evidence:
- Release decision: Pending

## Results recorded during VM session

| Case | Status | Evidence and observation |
| --- | --- | --- |
| P4-01 Baseline and normal GUI | Pass | Windows 11 Pro 25H2 build 26200.9445; account `User`; collector non-elevated; 39/39 states readable; guest script SHA256 matched local 0.6.3. |
| P4-02 Full preferred preview | Pass | JSON reported version 0.6.3, WhatIf, success/exit 0, changed false, non-elevated, 39/39 available and one expected update-policy advisory. |
| P4-03 Reversible account setting | Pass | `never-combine` alone moved Partial to Preferred; Explorer restarted; observed taskbar behavior changed; no other captured state changed. |
| P4-04 UAC cancellation | Pass | Cancelling the OneDrive machine-policy prompt returned control to Dingo; all 39 states remained identical and readable. |
| P4-05 Approved elevation and repeat | Pass | OneDrive alone moved Alternate to Preferred after approval. CLI repeat exited 0; both DWORD components were identical before/after and reported `Unchanged`; all 39 captured states remained identical. |
| Single-instance guard | Pass | CLI attempt while GUI was open exited 3 without applying; rerun after closing GUI prompted for UAC and succeeded. |
| P4-06 Existing tools | Pass | CLI exited 0. Log says 7-Zip 26.02 and Notepad++ 8.9.7 were already installed and left unchanged. No installer dispatch appeared; all 39 states were unchanged. |
| P4-07a Missing per-user tool | Pass | ripgrep installed through winget with `--scope user`, `--no-upgrade`, silent/noninteractive flags and no UAC. Dingo detected 15.2.0; a fresh shell resolved the WinGet package path and `rg --version` executed successfully. Only `tool-ripgrep` changed. |
| P4-09a Notepad++ associations on 0.6.3 | Fail; fixed and registry-retested | `.ini` Open with fallback succeeded, but five unprotected defaults became partial: `New-Item -Force` on each parent extension key removed the `OpenWithProgids` child written immediately beforehand. Per-extension output correctly exposed the partial mutations. In 0.6.4, repair from that partial state exited 0: all six commands/Open with entries verified, `.ini` retained its protected choice, the card became Preferred, and no unrelated state changed. |
| P4-09b Explorer behavior on 0.6.4 | Pass, with baseline limitation | Explorer opened the JSON sample directly in Notepad++. Double-clicking INI showed Windows' app chooser with Notepad labelled default and Notepad++ suggested as New; Open with also offered both. This verifies the fallback is discoverable. INI behavior before Dingo was not tested, so the chooser cannot be attributed to Dingo and the prior UserChoice's effective behavior remains unknown. |
| P4-10a Association reversal and Explorer behavior | Pass on 0.6.5 | Before evidence showed only `.json` retained as `OpenWithOnly`, with `ConfiguredOpenWithRegistered=False` and `ExplorerOpenWithRegistered=True`. After applying removal, the Notepad++ association card moved Partial to Alternate; `.json` became Available with both Open With locations false. The other 38 setting states were identical. Double-clicking JSON then opened Windows' app chooser instead of Notepad++. The shared ProgID command and `.ini`'s unrelated AppX UserChoice remained intact. |

These are registry/state-reader and operator observations as specified by each case. They do not expand the verification basis claimed by Dingo.

The 0.6.5 Explorer FileExts correction passes all 53 isolated regression checks on Windows PowerShell 5.1 (21 Phase 1, 22 Phase 2, and 10 Phase 3), plus a clean parser check and the targeted live VM retest above.

## Resume point

Preserve the current VM and evidence before continuing. Resume with the untested portion of P4-07, then P4-08, P4-11, and P4-12. Prepare and review the deliberate fixtures before P4-F01 through P4-F06. Finish with an end-to-end run from a known snapshot before making a release decision.
