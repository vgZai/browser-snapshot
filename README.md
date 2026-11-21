# Browser Snapshot

A small Windows app that automatically snapshots your **Chrome, Brave, and Edge** tab sessions, and restores every window and tab in one click — even after a crash, or after a reboot where the browser's own Restore button has disappeared.

- Takes a snapshot at logon and every 3 hours, and whenever you click **Snapshot now**
- Keeps the 10 newest regular snapshots, plus 5 extra pre-restore safety copies
- **Restore** closes the browser cleanly, copies the session files back, and relaunches with those tabs
- Works after a crash: it marks the profile as having closed normally, so you get your tabs back instead of a blank window

## Install

1. Download the zip from [Releases](../../releases) and extract it anywhere.
2. Right-click `install-tasks.ps1` and choose **Run with PowerShell**. That registers a logon task and a 3-hour task, and puts a **Browser Snapshot** shortcut on your desktop.
3. Double-click the shortcut to pick a snapshot and restore.

Windows may warn that the script is unsigned. That's expected for a script you just downloaded. From a PowerShell prompt in the extracted folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-tasks.ps1
```

To remove the tasks and the desktop shortcut later:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-tasks.ps1 -Uninstall
```

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (included with Windows)
- Chrome, Brave, and/or Edge

Snapshots are stored in a `snapshots` folder next to the scripts, on your PC only. They are not included in this repo or in the release zip.

## Files

| File | What it does |
| --- | --- |
| `restore.ps1` | The app: lists snapshots, restores one, or takes one now |
| `snapshot.ps1` | Takes a snapshot and prunes old ones |
| `run-hidden.vbs` | Silent launcher used by the scheduled tasks |
| `install-tasks.ps1` | Registers or removes the logon and 3-hour tasks, and a desktop shortcut |
| `snapshot.ico` | App icon |

## License

MIT.
