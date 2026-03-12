---
layout: default
title: Tools Reference
---

# Tools Reference

Windows Clippy MCP provides **40+ tools** for Windows desktop automation and Microsoft 365 integration.

---

## Core Interaction

| Tool | Purpose |
|------|---------|
| Launch-Tool | Launch an application from the Start menu. |
| Powershell-Tool | Run a PowerShell command and capture output. |
| State-Tool | Dump active app, open apps, interactive / informative / scrollable elements, plus optional screenshot. |
| Clipboard-Tool | Copy text to clipboard or paste current clipboard contents. |
| Click-Tool | Click at `(x, y)` with configurable button/clicks. |
| Type-Tool | Type text into the UI with optional clear. |
| Switch-Tool | Bring a window (e.g., "notepad") to the foreground. |
| Scroll-Tool | Vertical / horizontal scrolling at coordinates. |
| Drag-Tool | Drag from `(x1, y1)` to `(x2, y2)`. |
| Move-Tool | Move mouse cursor. |
| Shortcut-Tool | Send keyboard shortcut list (e.g., `["win","r"]`). |
| Key-Tool | Press single key (Enter, Esc, F1-F12, arrows, etc.). |
| Wait-Tool | Sleep for N seconds. |

---

## Web & Browser

| Tool | Purpose |
|------|---------|
| Browser-Tool | Launch Microsoft Edge and navigate to URL. |
| Scrape-Tool | Fetch a webpage and return Markdown. |

---

## Window Management

| Tool | Purpose |
|------|---------|
| Window-Tool | Minimize, maximize, restore, close, or resize windows. |
| TaskView-Tool | Open Task View, create/close/switch virtual desktops. |
| Taskbar-Tool | Interact with taskbar, start menu, system tray. |

---

## Screenshot & Visual

| Tool | Purpose |
|------|---------|
| Screenshot-Tool | Capture full screen, region, or active window. |
| Snip-Tool | Open Windows Snipping Tool for annotated captures. |
| Screen-Info-Tool | Get information about connected monitors. |
| Cursor-Position-Tool | Get current mouse cursor position. |

---

## System Control

| Tool | Purpose |
|------|---------|
| Volume-Tool | Control system volume: mute, unmute, set level, up/down. |
| Lock-Tool | Lock workstation, sign out, sleep, hibernate, shutdown, restart. |
| ActionCenter-Tool | Open Quick Settings or Notifications panel. |
| Emoji-Tool | Open Windows Emoji picker (Win+.). |
| Clipboard-History-Tool | Open Windows Clipboard History (Win+V). |
| Run-Dialog-Tool | Open Run dialog and optionally execute commands. |

---

## Settings & Configuration

| Tool | Purpose |
|------|---------|
| Settings-Tool | Open specific Windows Settings pages (35+ pages supported). |
| Registry-Tool | Read Windows Registry values (read-only for safety). |
| Wifi-Tool | List networks, connect, disconnect, get WiFi status. |
| Bluetooth-Tool | Open Bluetooth settings or check device status. |

---

## File & Process

| Tool | Purpose |
|------|---------|
| File-Tool | Create, delete, rename, copy, move, read, write files. |
| FileExplorer-Tool | Open File Explorer at specific path. |
| Process-Tool | List running processes or kill by name/PID. |
| SystemInfo-Tool | Get CPU, memory, disk, OS, network, battery info. |
| Search-Tool | Perform Windows Search for files, apps, settings. |

---

## Text Editing

| Tool | Purpose |
|------|---------|
| Text-Select-Tool | Select text (all, word, line, from cursor). |
| Find-Replace-Tool | Open Find or Find and Replace dialog. |
| Undo-Redo-Tool | Perform undo/redo operations. |
| Zoom-Tool | Zoom in/out or reset zoom in active application. |

---

## Notifications

| Tool | Purpose |
|------|---------|
| Notification-Tool | Display Windows toast notifications. |

---

## Microsoft 365 & Power Platform

These tools require appropriate Microsoft 365 licenses, PowerShell modules, and API permissions.

| Tool | Purpose |
|------|---------|
| PAC-CLI-Tool | Execute Power Platform CLI commands for app management. |
| Connect-MGGraph-Tool | Authenticate with Microsoft Graph API. |
| Graph-API-Tool | Execute Microsoft Graph API calls for Office 365 data. |
| Copilot-Studio-Tool | Manage and interact with Copilot Studio bots. |
| Power-Automate-Tool | Create and manage Power Automate workflows. |
| M365-Copilot-Tool | Interact with Microsoft 365 Copilot features. |

### Setup

```powershell
# Microsoft Graph PowerShell SDK
Install-Module Microsoft.Graph -Scope CurrentUser

# Microsoft Teams PowerShell
Install-Module MicrosoftTeams -Scope CurrentUser
```

For Power Platform CLI, download from the [official docs](https://docs.microsoft.com/en-us/power-platform/developer/cli/introduction).
