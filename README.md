# Dingo

A self-contained, state-aware PowerShell/WPF utility for applying a repeatable set of Windows 11 VM preferences.

## Run it

1. Copy the entire Dingo folder to the VM.
2. Double-click Start-Dingo.cmd.
   Do not use **Run as administrator**. Dingo keeps its main window in your signed-in account and asks for administrator credentials later, only when needed.
3. Choose the **My account**, **Whole computer**, **My account + whole computer**, or **Tools** tab.
4. Each card explains the normal Windows choice, the current choice, and the available choices in plain language.
5. Tick the cards to change, or use **Choose all my preferred settings**.
6. Choose **Apply checked changes**. Windows requests administrator approval when the selection includes a whole-computer setting or a protected account policy marked **Admin approval required**.

No installation or PowerShell modules are required. Windows PowerShell 5.1 is included with Windows 11.

## Quick apply without the GUI

Use the same launcher with `-ApplyPreferred` to apply all 36 preferred settings without opening the selection window:

```bat
Start-Dingo.cmd -ApplyPreferred
```

The examples use the launcher so errors remain visible when it is double-clicked. From an existing PowerShell console, you can use `./Dingo.ps1` in place of `Start-Dingo.cmd`.

Dingo still runs as the signed-in user and displays a Windows administrator prompt when the plan contains protected or whole-computer settings. Do not apply changes from an elevated console. Preview the plan without changing anything with:

```bat
Start-Dingo.cmd -WhatIf
```

Limit the plan by stable setting ID, using either repeated values or a comma-separated list:

```bat
Start-Dingo.cmd -ApplyPreferred -Include widgets,taskbar-search
Start-Dingo.cmd -WhatIf -Exclude language-au,windows-update-continuity
```

Add `-NoRestartExplorer` to suppress the automatic File Explorer restart. Exit code `0` means the plan succeeded (or a dry run completed), `1` means at least one setting failed or was only partially applied, `2` means the command or environment was invalid, and `3` means Dingo was already running.

`-ApplyPreferred` refuses to run from an elevated console, because Dingo must keep account settings pointed at your signed-in profile. `-WhatIf` is allowed there, because a dry run changes nothing; its JSON output carries `"Elevated": true` and the text output prints a note, so you know account settings were read from the elevated account. The three self-tests also run either way. This matters in Windows Sandbox, where every process is elevated.

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
- Twenty-five settings offer plainly labelled reversible choices. The five one-way targets are UTC, Australian region, Australian language, ISO date/time formats, and Widgets removal. The six tool cards are also one way: Dingo installs a tool but never removes it. Each can be left alone by unticking its card.
- **Read settings again** rereads every configured value without making changes.
- Preflight is all-or-nothing: an unsupported plan is stopped before any changes. Once application begins, an individual setting failure does not stop later selected settings from running.
- Logs are written to the `Logs` folder beside the script, so a copy deployed to `C:\DFIR\Tools\Dingo` logs to `C:\DFIR\Tools\Dingo\Logs`. The GUI can open that folder. Dingo keeps the 20 most recent logs and deletes older ones on the next launch.
- Dingo permits only one normal GUI or quick-apply run per Windows account, preventing concurrent settings and result-file races. Read-only help, version, catalog, and internal self-test commands do not take the instance lock.
- GUI and quick-apply modes use the same setting executor, administrator broker, verification, structured results, and logs.
- Before applying a plan, Dingo checks every selected setting's handler, required Windows commands, readable current state, and declared edition/build requirements. If any preflight check fails, the plan is stopped before changes or administrator approval begin.
- Setting types are registered in an internal handler catalog that owns their scope, state reader, apply function, and prerequisites. This keeps the single-file distribution while providing an extension point for future handlers, such as file associations. Tool installs use a `Package` handler on this same registry, and shortcuts use a `Shortcut` handler.
- The window stays open while an administrator operation is active so Dingo can collect its results, verify changes, and remove temporary protocol files. Abandoned protocol files older than 24 hours are removed on a later launch.
- The tool is idempotent: rerunning it writes and verifies the same desired values.
- OneDrive is disabled with policy. It is not uninstalled, and user files are not deleted.
- Windows Widgets is removed only from the signed-in account. Dingo stops that account's `Widgets`, `WidgetService`, and `WidgetBoard` processes by exact name so unrelated tools on an analyst VM are not terminated, uninstalls `Microsoft.WidgetsPlatformRuntime` and `MicrosoftWindows.Client.WebExperience`, and verifies the result using that same account's live AppX package state. Other profiles are left unchanged, and Dingo does not provide a reinstall action.
- The Windows Copilot setting also removes Copilot shortcuts that Windows exposes in the signed-in user's standard taskbar pin folder; it does not uninstall Copilot apps.
- Windows Terminal's settings.json is serialized and validated before it atomically replaces the live file. Every change creates a uniquely named backup, and Dingo keeps the 10 most recent backups per settings file.
- Windows Terminal ships its settings as JSONC, which permits `//` and `/* */` comments and trailing commas. Windows PowerShell 5.1 cannot parse those, so Dingo removes them before reading. Text inside string values, such as a `https://` URL, is left alone. Rewriting the file writes plain JSON: any comment you added survives in the backup but not in the new file.
- The Edge clutter setting removes the new tab page news feed and weather (`NewTabPageContentEnabled`), background images (`NewTabPageAllowedBackgroundTypes` = 3, DisableAll), and quick links (`NewTabPageQuickLinksEnabled`), plus Collections, shopping, Rewards, wallet donations, Insider and default-browser promotions, the web widget, feedback, alternate error pages, asset delivery, and telemetry. It sends Do Not Track and blocks Copilot's Discover Chat extension (`ofefcgjbeghpigppfmkologfjadafddi`). Every value is removable, so the card reverses cleanly. Restart Edge to finish applying it. The three new-tab-page values are the ones that matter most and are not covered by Chris Titus Tech's WinUtil Edge debloat.
- Showing protected operating-system files is intentionally marked with a caution.
- On Windows 11 Pro, Enterprise, or Education, the optional **Forensic continuity: manual updates and restarts** policy prevents Windows Update from automatically downloading or installing updates, disables update deadline enforcement, blocks update-driven restarts while a user is signed in, and suppresses all Windows Update notifications. This trades automatic patching for uninterrupted evidence processing: operators must check, install, and restart during a controlled maintenance window.

## Important limitations

- Microsoft now ships Copilot in several forms. The Windows setting applies the legacy Windows Copilot policy and hides integrated UI, but does not uninstall the newer standalone app. Microsoft recommends AppLocker or managed uninstall policy for centrally blocking that app.
- **Edge search engines are set with `ManagedSearchEngines`, not `DefaultSearchProvider*`.** Edge treats `DefaultSearchProvider*` as a protected policy and blocks it on any device that is not domain joined, Entra joined, or Intune enrolled, reporting `Error, Ignored` at `edge://policy`. `ManagedSearchEngines` is not protected and does apply. It replaces the whole engine list, so Bing is never created rather than removed. Dingo writes it to the `Recommended` key so an analyst can still change engines afterwards, and clears the five `DefaultSearchProvider*` values because `DefaultSearchProviderSearchURL` suppresses `ManagedSearchEngines`. Only the default entry may carry `is_default`: adding `"is_default": false` to another entry makes Edge reject the whole policy with no error anywhere. Restart Edge to finish applying it. Verified on Edge 152, Windows 11 25H2, unmanaged.
- On a profile where someone already chose a search engine by hand, that choice is kept. The policy still removes Bing from the list. A freshly imaged VM has no such choice, so it takes effect there.
- Every other Edge policy Dingo writes was confirmed applied on an unmanaged instance, with none reported as ignored: `edge-first-run` (6 values), `edge-passwords` (4), `edge-copilot` (5), and `edge-debloat` (16 visible on the policy page, plus one under `EdgeUpdate`). `DefaultSearchProvider*` was the only blocked family, and Dingo no longer uses it.
- To check any Edge policy yourself, restart Edge, visit `edge://policy`, click **Reload policies**, then **Export to JSON**. Each policy in that file carries an `ignored` flag and an `error` string, which is far quicker than guessing from behaviour.
- Removing the entire Recommended section is edition/build dependent. The tool disables recent and suggested content and applies the section-hiding policy where available.
- Microsoft does not ship a standalone full display pack for English (Australia). Windows exposes **English (Australia)** as a selectable interface language once the British English (`en-GB`) base resources are installed. Dingo installs that underlying display pack when needed, then selects `en-AU` for the Windows interface, input, spelling, regional formats, and system locale. Windows applies and reports the requested UI language after sign-out or restart.
- While a language pack is downloading, Dingo keeps its window responsive, shows the elapsed time in the status area, and records an installation heartbeat in the log every 30 seconds. Other controls remain disabled until the administrator step finishes so that settings cannot be applied twice concurrently.
- Dingo isolates its WPF interface from elevation operations by delegating administrator approval to a separate non-WPF broker process. It avoids fragile `Shell.Application` enumeration during state scans; Copilot policies and ordinary taskbar shortcuts are handled directly, while an opaque packaged-app pin may need to be unpinned manually.
- When a language-profile change is pending, Dingo registers a one-time sign-in finalizer for its ISO date/time preference. This reapplies the custom formats after Windows finishes initialising the new language, preventing Windows from replacing them with the locale defaults.
- Long-path, OneDrive, and Copilot changes can require a restart.
- The forensic-continuity policy cannot cancel an update restart that was already pending when it was applied. Choose **Another time**, apply the policy, and perform the pending restart manually when evidence processing is safely stopped. Domain, Intune/MDM, or other management policy can reapply conflicting update settings; verify Dingo still reports the protected state before starting a long-running acquisition or processing job.
- Windows Terminal must have been launched at least once so its settings file exists.
- Tool installs use winget, which needs a working network connection and the Microsoft `winget` source. If winget itself is missing, preflight stops the plan and says so, rather than failing halfway through an install.
- A winget install is given 15 minutes before Dingo gives up on it and stops the process. winget's own output is written to the log on both success and failure.
- Dingo installs tools. It never uninstalls or downgrades one. A tool already present is reported as installed and left alone, whatever version it is.
- If winget reports that a package is already present with nothing newer available, Dingo treats that as a success, because the tool is installed either way. Detection normally prevents this from happening at all.
- `-ApplyPreferred` now installs missing tools as well as changing settings, because "installed" is the preferred state for a tool card. Use `-Exclude` with the `tool-` IDs, or `-Include`, if you want settings only.
- A tool can declare that it needs another tool, with a `requires` list. When the other tool is absent, the card shows an amber caveat saying the tool will not start, and the same text appears as `Advisory` in `-WhatIf -OutputFormat Json`. A caveat never blocks the plan, because that would stop unrelated settings from being applied.
- Eric Zimmerman's tools are built on .NET 9, and a fresh Windows 11 install does not include it. Without it every tool fails to start with `You must install .NET to run this application`. Dingo therefore offers **.NET 9 Desktop Runtime** as its own card, listed before the tools that need it so a single run installs them in the right order. This was found by testing in Windows Sandbox, which is as bare as a freshly imaged VM.
- Dingo detects Eric Zimmerman's tools by looking for **Timeline Explorer** and **Registry Explorer**, not for a command-line tool. A partial copy holding only the command-line tools is common, and detecting on those would wrongly report a complete install.
- The `script` install kind downloads a PowerShell script and runs it with administrator rights. That is how the author distributes these tools, and it is the same thing you would do by hand. Dingo refuses any address that is not `https://`, and logs the URL and the SHA256 of the file it actually ran.
- Re-running the Eric Zimmerman install updates the tools in place, because the author's script only fetches what has changed. A tool card stays tickable after it reports installed, so ticking it again is how you update.
- Eric Zimmerman's tools land in `C:\DFIR\Tools\EZTools\net9`, in a mixed layout: some tools are a loose `.exe`, others get their own folder. Tick **Run tools from anywhere** to reach them from any folder.
- Dingo reads the computer PATH without expanding it and writes it back as an expandable value. Real machines hold entries such as `%USERPROFILE%\go\bin`, and reading PATH the easy way expands those, which would permanently bake one account's folders into the computer PATH. The self-test proves this on a stand-in value before anything is written.
- A PATH change reaches new windows only. Restart any open terminal, and sign out and back in for programs started from Explorer.
- Tool file associations and Desktop or Start Menu shortcuts are not built yet.

## Settings included

Thirty-six settings. Six install tools. Two make shortcuts, and one puts the tools on the PATH. The ID in the first column is the stable name used by `-Include` and `-Exclude`. **Scope** is whose settings change, and **Admin** is whether Windows asks for administrator approval. Run `Start-Dingo.cmd -ListSettings` for the same list from the tool itself.

### Region and language

| ID | Setting | Scope | Admin | Preferred |
| --- | --- | --- | --- | --- |
| `timezone-utc` | Time zone | System | yes | UTC |
| `region-australia` | Region and formats | User | no | Australia (en-AU) |
| `language-au` | Australian English | Both | yes | en-AU interface and locale |
| `iso-time` | Date and time format | User | no | yyyy-MM-dd, 24-hour |

### Taskbar

| ID | Setting | Scope | Admin | Preferred |
| --- | --- | --- | --- | --- |
| `taskbar-search` | Search box | User | no | Hidden |
| `task-view` | Task View button | User | no | Hidden |
| `widgets` | Windows Widgets | User | no | Removed for this account |
| `resume` | Cross-device Resume | Both | yes | Disabled |
| `never-combine` | Combine taskbar buttons | User | no | Never combine |
| `end-task` | End task on right-click | User | no | Enabled |

### File Explorer

| ID | Setting | Scope | Admin | Preferred |
| --- | --- | --- | --- | --- |
| `explorer-this-pc` | Default landing page | User | no | This PC |
| `hidden-files` | Hidden files and folders | User | no | Shown |
| `file-extensions` | File-name extensions | User | no | Shown |
| `protected-files` | Protected operating-system files | User | no | Shown (caution) |
| `expand-nav` | Expand navigation pane | User | no | Enabled |
| `long-paths` | Win32 long paths | System | yes | Enabled |

### Windows features and updates

| ID | Setting | Scope | Admin | Preferred |
| --- | --- | --- | --- | --- |
| `onedrive` | OneDrive file sync | System | yes | Disabled by policy |
| `windows-copilot` | Windows Copilot and taskbar icon | Both | yes | Disabled |
| `windows-update-continuity` | Forensic continuity: manual updates and restarts | System | yes | Protected, manual maintenance |

### Microsoft Edge

| ID | Setting | Scope | Admin | Preferred |
| --- | --- | --- | --- | --- |
| `edge-first-run` | First-run and import extras | System | yes | Suppressed |
| `edge-passwords` | Edge password manager | System | yes | Disabled |
| `edge-copilot` | Copilot in Edge | System | yes | Disabled |
| `edge-search-engines` | Search engines | System | yes | Google and DuckDuckGo, no Bing |
| `edge-debloat` | Clutter, promotions, and new tab page | System | yes | Removed |

### Windows Terminal and Start menu

| ID | Setting | Scope | Admin | Preferred |
| --- | --- | --- | --- | --- |
| `terminal-cwd` | Windows PowerShell starting directory | User | no | Parent process directory |
| `start-bing` | Bing/web search | User | yes | Disabled |
| `start-recommendations` | Recommendations | Both | yes | Disabled |

### Tools

Tool cards live on their own **Tools** tab. Dingo checks whether each tool is already installed, and installs the missing ones with winget. Dingo never uninstalls a tool, so these cards are one-way and have no second option.

| ID | Tool | Scope | Admin | Preferred |
| --- | --- | --- | --- | --- |
| `tool-7zip` | 7-Zip | System | yes | Installed |
| `tool-notepadplusplus` | Notepad++ | System | yes | Installed |
| `tool-ripgrep` | ripgrep | User | no | Installed |
| `tool-sqlitebrowser` | DB Browser for SQLite | System | yes | Installed |
| `tool-dotnet-desktop-9` | .NET 9 Desktop Runtime | System | yes | Installed |
| `tool-eztools` | Eric Zimmerman's tools | System | yes | Installed |
| `tools-start-menu` | Start menu shortcuts | System | yes | Created |
| `tools-desktop` | Desktop shortcuts | System | yes | Created |
| `tools-on-path` | Run tools from anywhere | System | yes | On the PATH |

A tool installs machine-wide where its winget package supports it, which needs administrator approval. ripgrep ships as a portable package, so it installs into the signed-in account only and needs no approval. winget adds ripgrep to the user PATH by itself.

Eric Zimmerman's tools are not in winget. Dingo runs the author's own `Get-ZimmermanTools.ps1` instead, fetched over https from `EricZimmerman/Get-ZimmermanTools` on GitHub, and installs into `C:\DFIR\Tools\EZTools`. The SHA256 of the downloaded script is written to the log before it runs, so you can audit what was executed. That download is several hundred megabytes and is given 45 minutes.

**Run tools from anywhere** is not a tool. It writes one small `.cmd` launcher for each installed command-line program into `C:\DFIR\Tools\bin`, then adds that single folder to the computer PATH. You can then type `EvtxECmd -d "path"` from any folder.

Eric Zimmerman's tools need this because `C:\DFIR\Tools\EZTools\net9` has a mixed layout: some tools are a loose `.exe`, others sit in their own folder. Putting all of those on the PATH would mean about 30 entries. One launcher folder means one entry.

The folder is added to the **end** of the PATH, so a tool can never shadow a Windows command such as `find` or `where`.

This card is reversible. Turning it off removes the PATH entry and deletes the launchers. Dingo only ever deletes `.cmd` files that carry its own marker line, so anything you put in that folder by hand is left alone. Already-open windows keep the old PATH until they are restarted.

This card is applied last, after the tools its launchers point at, so installing a tool and putting it on the PATH can be done in a single run.

**Start menu shortcuts** and **Desktop shortcuts** are not tools either. Some installers make no shortcut at all, so the program sits on disk and nobody can find it. `Get-ZimmermanTools.ps1` is the clearest case: it makes none. These two cards write a shortcut for each installed window tool.

| Card | Where the shortcuts go |
| --- | --- |
| `tools-start-menu` | `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\DFIR Tools` |
| `tools-desktop` | `C:\Users\Public\Desktop` |

Both locations are shared, so the shortcuts appear for every account on the computer. Both cards are applied after the tool cards, so installing a tool and getting its shortcut can be done in a single run.

Seven shortcuts are offered today, all from Eric Zimmerman's set: Timeline Explorer, Registry Explorer, MFT Explorer, ShellBags Explorer, Jump List Explorer, SDB Explorer, and EZViewer. Only the window tools are listed. A command-line tool is reached through **Run tools from anywhere** instead. 7-Zip, Notepad++, and DB Browser for SQLite make their own Start menu entries, so Dingo does not add more.

A shortcut whose program is not on disk is skipped, not reported as a failure. Its working folder is set to the folder the program lives in, because several of these tools read their own files from beside themselves.

Both cards are reversible. Turning one off removes only shortcuts that carry Dingo's marker in the shortcut comment, so a shortcut you made by hand, or one an installer made, is left alone. Turning off the Start menu card also removes the `DFIR Tools` folder, but only when it is empty. The shared Desktop folder belongs to Windows and is never removed.

Detection does not depend on winget. Dingo reads the Windows uninstall list under both HKLM and HKCU, checks the usual install folders, and looks on the PATH. A tool installed by hand, or by Chocolatey, is still found.

## Adding your own tools

Put a `Tools.json` file next to `Dingo.ps1`. A new `id` adds a tool. An `id` that matches a built-in one replaces it. Comments and trailing commas are allowed.

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
| `id` | yes | Must look like `tool-example`: lower case, digits, and hyphens |
| `name` | yes | Shown on the card |
| `category` | no | Defaults to `Tools` |
| `description` | no | Defaults to "Install \<name\>" |
| `install.kind` | no | `winget` (default) or `script` |
| `install.package` | winget only | The exact winget package id |
| `install.url` | script only | `https://` address of the install script. Plain `http` is refused |
| `install.dest` | script only | Folder the script installs into. Dingo creates it if needed |
| `install.arguments` | no | Extra arguments for the script. `-Dest` is always passed for you |
| `install.timeoutMinutes` | no | 1 to 240. Defaults to 15 for winget and 45 for a script |
| `install.scope` | no | `machine` (default) or `user`. This decides whether the card needs administrator approval |
| `install.source` | no | winget only. Defaults to `winget` |
| `detect` | yes | One or more rules. The first rule that matches wins |
| `requires` | no | List of other tool IDs this one needs. The card warns when one is missing |
| `shims.from` | no | Folder to scan for command-line programs. Adding this block puts the tool's programs on the PATH |
| `shims.pattern` | no | Defaults to `*.exe` |
| `shims.recurse` | no | Defaults to `true` |
| `shortcuts` | no | List of window programs that need a Start menu or Desktop shortcut |
| `shortcuts[].name` | yes, inside the list | The shortcut name. It becomes a file name, so `\`, `/`, and `:` are refused |
| `shortcuts[].target` | yes, inside the list | The program the shortcut opens. Skipped quietly when it is not on disk. Write it with forward slashes |
| `shortcuts[].arguments` | no | Extra arguments passed to the program |

Detect rule kinds:

| Kind | Field | Meaning |
| --- | --- | --- |
| `uninstall-key` | `match` | Wildcard match on the Windows uninstall display name, for example `7-Zip*` |
| `file` | `path` | A file that must exist, or a wildcard such as `.../Microsoft.WindowsDesktop.App/9.*` to match a versioned folder whose exact patch number is unknown. A matched folder reports its own name as the version. `%ProgramFiles%` and other environment names are expanded. A backslash starts an escape in JSON, so write the path with forward slashes, or double every backslash |
| `command` | `command` | An executable that must be on the PATH, for example `rg.exe` |

A tool entry Dingo cannot understand is skipped, and the reason is written to the log and shown at the top of the Tools tab. A `Tools.json` that will not parse at all is ignored, and the built-in list is used instead. Dingo still starts either way.

`Tools.json` names commands that Dingo will run. Treat it with the same care as `Dingo.ps1` itself.

## Credits

**[Chris Titus Tech's WinUtil](https://github.com/ChrisTitusTech/winutil)** has been an excellent resource for this project, and deserves the credit. Its `EdgeDebloat` tweak is a well-researched, working list of Edge policies that genuinely apply on an ordinary standalone machine, which is exactly the hard part. Most of Dingo's `edge-debloat` setting comes from that list.

Just as usefully, WinUtil showed what to avoid. It sets no search-engine policy at all, and that absence was the clue that Microsoft treats the default search provider as a protected policy which Windows silently refuses to honour on a machine that is not domain joined, Entra joined, or Intune enrolled. That saved a lot of guesswork and led Dingo to `ManagedSearchEngines` instead.

WinUtil is a reference only. Dingo does not bundle, download, or execute any part of it, and the two projects are unrelated. If you want a broader Windows utility that goes well past preferences, use WinUtil directly.

Other sources:

- Microsoft's [Edge policy reference](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies) and Windows settings documentation, for every policy name, type, and permitted value.
- Eric Lawrence's [Managing Edge via Policy](https://textslashplain.com/2020/08/24/managing-edge-via-policy/), which explains why some Edge policies are marked "protected" and ignored on unmanaged devices.
