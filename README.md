# WEP — Antigravity Remote Ecosystem (Windows Gateway + iOS App)

**WEP** lets you control **Google Antigravity (`agy`)** and edit code directly on your always-on home Windows PC from your **iPhone** — over LAN Wi-Fi or anywhere via **Cloudflare Tunnel**.

## Components

1. **WEP Host (`windows/WEP.Host`)** — Windows `.NET 9` WPF Desktop App & System Tray Gateway:
   - Embedded ASP.NET Core Kestrel REST + WebSocket server (`Port 8420` by default).
   - Auto-downloads & manages `cloudflared.exe` (Quick Tunnel `trycloudflare.com` or Named Tunnel with custom domain).
   - Generates a **QR Pairing Code** for instant 1-scan iPhone pairing.
   - Keeps PC awake, supports auto-start with Windows & minimize-to-tray.
   - Bridges `agy.exe --output-format stream-json`, remote drive/folder browsing, direct file read/write, Git status/diff, and PowerShell terminal execution.

2. **WEP iOS App (`ios/WEP`)** — Native SwiftUI iOS 17+ app styled after Antigravity:
   - Left-hand Antigravity Sidebar (New Conversation, Pinned Workspaces/Open Folder, Conversations, Pair/Settings).
   - Streaming Chat Canvas with Thinking accordions, expandable Tool Execution cards, `@` file mentions, `/` slash commands, Model & Mode (`Auto` / `Accept Edits` / `Plan`) selectors.
   - Remote Windows Drive & Folder Browser (`Open Folder in Antigravity`).
   - Direct Mobile Code Editor with coding symbol bar & `Save to Windows PC`.
   - Auxiliary Pane (`Files Changed` + Git Diff viewer, Tool Timeline) & Remote PowerShell Terminal.

## Build Windows App Locally
```powershell
dotnet build windows/WEP.Host/WEP.Host.csproj -c Release
```
Or publish a single runnable folder:
```powershell
dotnet publish windows/WEP.Host/WEP.Host.csproj -c Release -o dist/WEP.Host
```

## Build `WEP.ipa` via GitHub Actions
Push this repository to GitHub (`main` branch). `.github/workflows/build-ipa.yml` runs on `macos-latest`, generates `WEP.xcodeproj` via XcodeGen, compiles `WEP.app`, packages `WEP.ipa`, and publishes it to Artifacts + the `latest` Release.
