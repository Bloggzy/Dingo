# Dingo

Dingo goes some way to set up a fresh Windows 11 machine for a DFIR analyst (Digital Forensics and Incident Response).

It does three jobs:

1. **Changes Windows settings** to suit an analyst: UTC time, ISO dates, 24-hour clock, hidden files shown, file extensions shown.
2. **Removes Windows clutter**: Widgets, Copilot, Bing in Start, OneDrive, Edge promotions.
3. **Installs core tools** and wires them in: Start menu and Desktop shortcuts, file associations, and a PATH entry so you can run the command-line tools from any folder.

Nothing is applied until you select it. Every change is shown on a card first, and all but one are reversible.

![Dingo main window: the Tweaks section open on the Whole computer tab, showing setting cards and the Tweaks, Tools, and Options sections](Assets/Dingo-main-screen-redacted.png)

Current version: **0.8.1**.

## Use the window

1. Copy the whole Dingo folder to the machine.
2. Double-click `Start-Dingo.cmd`. Do **not** use *Run as administrator*. Dingo asks for administrator rights later, only when it needs them.
3. Pick a section:
   - **Tweaks** - Windows settings (My account / Whole computer).
   - **Tools** - Install tools, Tool shortcuts, File associations.
   - **Options** - Dingo's own choices, such as the log folder and where tools are installed.
4. Turn on the switch on each card you want, or press **Choose all my preferred settings**.
5. Press **Apply selected changes**. Windows asks for approval if the plan touches the whole computer.

You need nothing else. Windows PowerShell 5.1 is already part of Windows 11.

## Use the command line

**In short:** to apply everything, the settings and the tools, run this:

```bat
Start-Dingo.cmd -Apply -Include tweaks,tools
```

The rest of this section is the detail.

Preview a plan. Nothing is changed:

```bat
Start-Dingo.cmd -WhatIf
```

Apply the preferred Windows settings:

```bat
Start-Dingo.cmd -Apply
```

Up to version 0.7.7 this switch was called `-ApplyPreferred`. That name still works as an alias, so
existing scripts and shortcuts do not need changing.

`-Apply` makes the changes and `-WhatIf` previews them. Neither one picks what to change; `-Include` and
`-Exclude` do that.

A bare `-Apply` applies the **Tweaks** section only. It installs no tools. The run prints that before it
starts, together with the number of tool cards it left alone. To include tools:

```bat
Start-Dingo.cmd -Apply -Include tools
Start-Dingo.cmd -Apply -Include tweaks,tools
```

`-Include` and `-Exclude` also take setting IDs, separated by commas:

```bat
Start-Dingo.cmd -Apply -Include widgets,taskbar-search
Start-Dingo.cmd -Apply -Include tools -Exclude tool-7zip
```

Other commands:

```bat
Start-Dingo.cmd -ListSettings
Start-Dingo.cmd -Help
Start-Dingo.cmd -Version
```

Add `-OutputFormat Json` to `-WhatIf`, `-Apply`, or `-ListSettings` for machine-readable output. In JSON, the apply mode is reported as `"Mode": "Apply"`. Add `-NoRestartExplorer` to skip the File Explorer restart.

### What a run prints

A run has two steps, and each one counts to its own total:

```
Dingo quick apply: applying 43 change(s).
Step 1 of 2: 26 of the 43 change(s) need administrator approval.
  1/26 Time zone
  2/26 Region and formats
  still working: Display language: Downloading - Windows is downloading the en-GB pack... [3:00 so far]
  26/26 Display language
Step 2 of 2: applying and checking all 43 change(s).
  1/43 [time-zone] Applying UTC...
  1/43 [time-zone] Succeeded: UTC
```

A change that is going to cost real time says so before the work starts, as a **Note** line. The display language is the one that matters: if this computer has no pack for the language you chose, Windows must fetch it from Windows Update, and that one step usually takes about ten minutes. Every other selected change still runs. Deselect the display language, or pick a language whose pack is already on the machine, to keep a run to a minute or two.

The word is **change**, not setting. A plan holds Windows settings, but also tools to install, shortcuts to write, file types to claim, and the PATH.

**Step 1** is the part Windows must approve. It runs first, in a second process, so it is counted out of its own total. A line appears as each change finishes.

**Step 2** is every selected change, the approved ones included. This is where each one is finished off and its final state read back, so this count is the whole plan.

A change that takes a long time, such as a language pack or a tool download, says `still working` once a minute with the time so far.

When the run ends, anything you still have to do is printed as a **Next** line:

```
Dingo finished: 42 succeeded; 1 partially applied; 0 failed. Log: ...
Next: Close this terminal and open a new one before the tool commands work. A PATH change reaches new windows only. The launchers are in C:\DFIR\Tools\bin.
Next: Display language needs you to sign out and back in, or restart Windows, before it can finish applying. Then run Dingo again to check.
```

The PATH line is left out when this terminal already has the folder, so it only appears when you really are waiting on something. A quiet screen never means a stopped run. Full detail goes to the log either way.

### Run the script directly

`Start-Dingo.cmd` is a convenience. It picks the right PowerShell switches for you and holds the window open if a run fails. For a command-line run you can call the script instead:

```powershell
.\Dingo.ps1 -Apply -Include tweaks,tools
```

Everything above works the same way. Two differences:

- **Tab completion works.** Type `.\Dingo.ps1 -` and press Tab. PowerShell reads the switches from the script. The `.cmd` cannot do this, because PowerShell cannot read the switches of a batch file.
- **The window does not wait.** A failed run closes straight away, so read the exit code or the log.

If PowerShell refuses to run the script, your machine blocks local scripts. Allow them for that one window:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Add `-ToolRoot` to use a different tools folder for one run, without saving it:

```bat
Start-Dingo.cmd -Apply -Include tools -ToolRoot "D:\DFIR\Tools"
```

A folder Dingo cannot use ends the run with exit code `2` and says why. See [Where tools are installed](#where-tools-are-installed) for the saved option and the rules.

Exit codes: `0` success, `1` a setting failed, `2` bad command line, `3` Dingo already running.

Do not apply changes from an elevated console. Dingo must stay in your signed-in account, so per-user settings land in the right profile.

## What it changes

Forty-three cards. The ID is what `-Include` and `-Exclude` accept. **Admin** means Windows asks for approval.

An ID names the setting, never a value it can hold. `time-zone`, not `timezone-utc`: UTC is one choice of many, and an ID that names it goes stale the day a second choice appears. A test holds this for every card that offers a list.

### Region and language

Each card offers a list to choose from.

| ID | Setting | Admin | Preferred |
| --- | --- | --- | --- |
| `time-zone` | Time zone | yes | UTC |
| `region` | Region and formats | no | Australia (en-AU) |
| `display-language` | Display language | yes | Australian English (en-AU) |
| `date-time-format` | Date and time format | no | yyyy-MM-dd HH:mm |

### Taskbar

| ID | Setting | Admin | Preferred |
| --- | --- | --- | --- |
| `taskbar-search` | Search box | no | Hidden |
| `task-view` | Task View button | no | Hidden |
| `widgets` | Windows Widgets | no | Removed for this account |
| `resume` | Cross-device Resume | yes | Disabled |
| `taskbar-combine` | Combine taskbar buttons | no | Never combine |
| `end-task` | End task on right-click | no | Enabled |

### File Explorer

| ID | Setting | Admin | Preferred |
| --- | --- | --- | --- |
| `explorer-landing` | Default landing page | no | This PC |
| `hidden-files` | Hidden files and folders | no | Shown |
| `file-extensions` | File-name extensions | no | Shown |
| `protected-files` | Protected system files | no | Shown (caution) |
| `expand-nav` | Expand navigation pane | no | Enabled |
| `long-paths` | Win32 long paths | yes | Enabled |

### Windows features and updates

| ID | Setting | Admin | Preferred |
| --- | --- | --- | --- |
| `onedrive` | OneDrive file sync | yes | Disabled by policy |
| `windows-copilot` | Windows Copilot | yes | Disabled |
| `windows-update` | Manual update configuration | yes | Configured |

### Microsoft Edge

Restart Edge after these.

| ID | Setting | Admin | Preferred |
| --- | --- | --- | --- |
| `edge-first-run` | First-run and import extras | yes | Suppressed |
| `edge-passwords` | Edge password manager | yes | Disabled |
| `edge-copilot` | Copilot in Edge | yes | Disabled |
| `edge-search-engines` | Search engines | yes | Google and DuckDuckGo, no Bing |
| `edge-debloat` | Clutter and new tab page | yes | Removed |

### Windows Terminal and Start menu

| ID | Setting | Admin | Preferred |
| --- | --- | --- | --- |
| `terminal-cwd` | PowerShell starting directory | no | Parent process directory |
| `start-bing` | Bing/web search | yes | Disabled |
| `start-recommendations` | Recommendations | yes | Disabled |

## Tools

Each tool card has two choices: **Installed** (install it if missing, leave it alone if present) and **Update installed tool**. Neither choice removes a tool.

The cards are shown in name order, and the **Install tools** tab has a search box above the list. Type part of a name, such as `haya`, and only the matching cards stay on screen. Type more than one word and a card must match every word. The search only hides cards; a tool you already selected stays in the plan while it is out of sight. Press **Clear** to show the whole list again.

| ID | Tool | Admin |
| --- | --- | --- |
| `tool-7zip` | 7-Zip | yes |
| `tool-notepadplusplus` | Notepad++ | yes |
| `tool-ripgrep` | ripgrep | no |
| `tool-sqlitebrowser` | DB Browser for SQLite | yes |
| `tool-dotnet-desktop-9` | .NET 9 Desktop Runtime | yes |
| `tool-dotnet-desktop-10` | .NET 10 Desktop Runtime | yes |
| `tool-eztools` | Eric Zimmerman's tools | yes |
| `tool-memprocfs` | MemProcFS | yes |
| `tool-volatility3` | Volatility 3 | yes |
| `tool-hayabusa` | Hayabusa | yes |
| `tool-duckdb` | DuckDB | yes |

Select .NET 9 as well as Eric Zimmerman's tools. Those tools need it, and a fresh Windows 11 does not have it. Dingo installs it first, so one run installs both in the right order.

.NET 10 is a separate card. Newer analyst tools are built on .NET 10, and a .NET 9 install does not satisfy them. The two runtimes sit side by side; installing one does not touch or replace the other.

The table above is the order Dingo installs in, not the order the window shows. The window sorts the cards by name so a growing list stays easy to read. The plan still runs in the order above, so a runtime is always installed before the tools that need it.

Most tools come from winget, so you need a network connection. Dingo also checks the winget version before it installs anything. A client older than 1.6 cannot read the package list Microsoft publishes today, and every install fails with `0x8a15000f`, "Data required by the source is missing". When Dingo is running as an administrator it repairs winget itself with `Repair-WinGetPackageManager`, then carries on. Otherwise it stops and tells you to install the latest App Installer from <https://aka.ms/getwinget>. Before it repairs anything, Dingo checks it can reach the App Installer download, and the PowerShell Gallery when the repair module is missing or too old. A computer with no route out is told so by name, rather than waiting for a download to time out. Eric Zimmerman's tools are not in winget. Dingo runs the author's own `Get-ZimmermanTools.ps1` over HTTPS and checks its SHA256 before running it. They install to `EZTools` inside the tools folder, `C:\DFIR\Tools` by default, and the download is several hundred megabytes.

MemProcFS, Volatility 3, Hayabusa, and DuckDB are not in winget either. Each one ships a zip on its own GitHub releases page, so Dingo reads the latest release, downloads the Windows file, and unpacks it into its own folder inside the tools folder:

| Tool | Folder | Command |
| --- | --- | --- |
| MemProcFS | `MemProcFS` | `MemProcFS` |
| Volatility 3 | `Volatility3` | `vol`, `volshell` |
| Hayabusa | `Hayabusa` | `hayabusa` |
| DuckDB | `DuckDB` | `duckdb` |

All four are command-line tools, so they get no Start menu or Desktop shortcut. Select **Run tools from anywhere** to type the commands above from any folder. Volatility 3 is the standalone Windows build, so no Python install is needed.

Hayabusa puts its version in the program name, such as `hayabusa-4.1.0-win-x64.exe`. Dingo always names the launcher `hayabusa` and points it at the newest copy in the folder, so the command never changes when you update.

Dingo builds the download address itself from the repository name, so a catalog entry can never send the download to another site. A release file is rebuilt for every version, so no SHA256 can be pinned in advance; Dingo records the hash of what it actually fetched in the log and the journal. Choose **Update installed tool** to fetch the newest release again.

### Where tools are installed

A tool with its own installer goes where that installer puts it. A tool without one, such as Eric Zimmerman's set, goes in Dingo's **tools folder**: `C:\DFIR\Tools` by default. Change it on the **Options** tab.

- The choice is saved in `%LOCALAPPDATA%\Dingo\config.json`. No administrator approval needed.
- The launcher folder is always `bin` inside the tools folder, so moving one moves both.
- Changing it moves nothing. A tool already installed stays where it is. Install it again to put it in the new folder.
- Dingo refuses a network path, a drive letter on its own, and anything inside `%SystemRoot%`, `%ProgramFiles%`, or `C:\Users`. The launcher folder goes on the computer PATH, so a standard account must not be able to write to it.

### Shortcuts and PATH

| ID | Card | What it does |
| --- | --- | --- |
| `tools-start-menu` | Start menu shortcuts | Writes shortcuts to `...\Start Menu\Programs\DFIR Tools` |
| `tools-desktop` | Desktop shortcuts | Writes shortcuts to `C:\Users\Public\Desktop` |
| `tools-on-path` | Run tools from anywhere | Puts the tools `bin` folder on the computer PATH |

**Run tools from anywhere** writes one small `.cmd` launcher per command-line tool into `bin` inside the tools folder, `C:\DFIR\Tools\bin` by default, then adds that one folder to the PATH. You can then type this from any folder:

```bat
EvtxECmd -d "C:\Evidence"
```

The folder goes at the **end** of the PATH, so no tool can shadow a Windows command such as `find`. A PATH change reaches new windows only. Restart any open terminal.

Shortcuts are written for window tools only, and only for tools that are on disk. 7-Zip, Notepad++, and DB Browser make their own Start menu entries, so Dingo does not add more.

All three cards are reversible. Turning one off removes only the files Dingo marked as its own.

### File associations

These are your account's choices, so no administrator approval is needed.

| ID | Card | Types |
| --- | --- | --- |
| `assoc-notepadplusplus` | Notepad++ | `.json` `.md` `.yml` `.yaml` `.ini` `.conf` |
| `assoc-eztools` | Eric Zimmerman's tools | `.csv` `.tsv` to Timeline Explorer, `.dat` to Registry Explorer |
| `assoc-sqlitebrowser` | DB Browser for SQLite | `.db` `.sqlite` `.sqlite3` |

Windows only lets Dingo take a file type that nothing has claimed yet. A type that already carries a user choice is locked by Windows, and no method can take it on a machine that is not domain joined. That is why `.txt` and `.log` are absent: Windows Notepad owns them and will not give them up. For any type it cannot take, Dingo adds an **Open with** entry instead, and the card names the types and says why.

Turning a card off puts back whatever the type pointed at before.

## Good to know

- Tools and their shortcuts can be done in one run. Tool cards run first, then shortcuts, associations, and PATH.
- Rerunning Dingo is safe. It writes and verifies the same values.
- A failed setting does not stop the rest. There is no automatic rollback, so a part-applied change stays visible in the results.
- Some settings need a sign-out or a restart. Dingo raises a dialog and names them.
- Widgets removal is the one change with no way back.
- Logs go to the `Logs` folder beside the script. Dingo keeps the 20 newest.
- Windows Terminal must have been opened once, so its settings file exists.
- A display language with no pack on the machine is a download of about ten minutes. Windows ships no Australian interface, so Australian English is supplied through the British pack with the language set to en-AU on top. Pick a language whose pack is already on the machine to skip the wait.
- Only one Dingo run per Windows account at a time.

Inspect a run that was interrupted:

```bat
Start-Dingo.cmd -RecoveryReport
```

A missing completion record means **unknown**, not safe. Read the settings again before you retry.

## Add your own tools

Put a `Tools.json` file next to `Dingo.ps1`. A new `id` adds a tool. A matching `id` replaces a built-in one.

Any path may hold `%DINGO_TOOL_ROOT%`, which Dingo replaces with the tools folder. Use it for a tool with no installer of its own. `%ProgramFiles%` and other environment variables work too.

```json
{
  "tools": [
    {
      "id": "tool-hxd",
      "name": "HxD",
      "category": "Text and data",
      "description": "Hex editor.",
      "install": { "kind": "winget", "package": "MHNexus.HxD", "scope": "machine" },
      "detect": [ { "kind": "uninstall-key", "match": "HxD*" } ]
    }
  ]
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `id` | yes | Like `tool-example`: lower case, digits, hyphens |
| `name` | yes | Shown on the card |
| `category` | no | Defaults to `Tools` |
| `description` | no | Defaults to "Install \<name\>" |
| `install.kind` | no | `winget` (default), `script`, or `github-release` |
| `install.package` | winget only | The exact winget package id |
| `install.url` | script only | `https://` address. Plain `http` is refused |
| `install.sha256` | no | Expected SHA256 for a script. A mismatch blocks it |
| `install.repo` | github-release only | The repository as `owner/name`. Dingo builds the address from it |
| `install.assetPattern` | github-release only | Wildcard for the release file, such as `duckdb_cli-windows-amd64.zip`. It must be a `.zip`, and must match exactly one file |
| `install.dest` | script and github-release | Folder to install into |
| `install.arguments` | no | Extra arguments. `-Dest` is always passed for you |
| `install.timeoutMinutes` | no | 1 to 240. Default 15 (winget), 30 (github-release), or 45 (script) |
| `install.scope` | no | `machine` (default) or `user` |
| `install.source` | no | winget only. Defaults to `winget` |
| `detect` | yes | One or more detect rules |
| `detectMode` | no | `any` (default) or `all` |
| `requires` | no | Other tool IDs this one needs |
| `shims.from` | no | Folder to scan for command-line programs, for the PATH card |
| `shims.pattern` | no | Defaults to `*.exe` |
| `shims.recurse` | no | Defaults to `true` |
| `shims.name` | no | One steady launcher name. Use it when the program name holds its version. Dingo then writes one launcher, pointing at the newest matching file |
| `shortcuts[].name` | yes, in the list | Becomes a file name, so slashes and colons are refused |
| `shortcuts[].target` | yes, in the list | The program. Use forward slashes |
| `shortcuts[].arguments` | no | Extra arguments |
| `associations[].extension` | yes, in the list | Must start with a dot |
| `associations[].target` | yes, in the list | The program that opens it |
| `associations[].description` | no | Type name Explorer shows, such as `JSON file` |

Detect rules:

| Kind | Field | Meaning |
| --- | --- | --- |
| `uninstall-key` | `match` | Wildcard on the uninstall display name, such as `7-Zip*` |
| `file` | `path` | A file that must exist. Wildcards allowed. Use forward slashes |
| `command` | `command` | A program on the PATH, such as `rg.exe` |

A tool entry Dingo cannot read is skipped, and the reason is logged. A broken `Tools.json` is ignored, and the built-in list is used. Dingo always starts.

`Tools.json` names commands Dingo will run. Treat it as carefully as `Dingo.ps1`.

## Build a release

```powershell
.\Build-Release.ps1 -Verify
```

This writes `Dingo-<version>.zip` beside the script and prints its SHA256. The version is read from `Dingo.ps1`, so the file name cannot disagree with what the script reports.

The package holds `Dingo.ps1`, `Start-Dingo.cmd`, `README.md`, `LICENSE`, and `Tools.example.json`. That list lives in the build script. A file that is missing stops the build rather than producing a package with a hole in it.

`-Verify` unpacks the finished zip into a temporary folder and runs the self-tests from there, which is what proves the package works on its own rather than only where it was built.

## Tests

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Phase1.Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Phase2.Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Phase3.Tests.ps1
```

All three suites run on Windows PowerShell 5.1 and on PowerShell 7. Phase 3 builds a small native probe with the
.NET Framework C# compiler that ships with Windows, so it needs no SDK.

These are isolated checks with mocked installers. They write no registry values. For real Windows validation, use the [Phase 4 VM test pack](Tests/Phase4/README.md) on a disposable VM, starting from a snapshot.

## Credits

**[Chris Titus Tech's WinUtil](https://github.com/ChrisTitusTech/winutil)** - most of Dingo's funtionality and features were inspired by this excellent project. Some of the Windows settings and tweaks, and the Edge debloat options come from WinUtil's well-researched `EdgeDebloat` list. WinUtil is a reference only. Dingo does not bundle or run any part of it.

- Microsoft's [Edge policy reference](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies), for policy names, types, and values.
- Eric Lawrence's [Managing Edge via Policy](https://textslashplain.com/2020/08/24/managing-edge-via-policy/), which explains why some Edge policies are ignored on unmanaged devices.
