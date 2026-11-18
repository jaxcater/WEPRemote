# WEP — Điều Khiển Antigravity & Code Từ Xa Trên iPhone

**WEP** là hệ thống điều khiển **Google Antigravity (`agy`)** và lập trình từ xa trên máy tính Windows ở nhà thông qua ứng dụng **WEP trên iPhone** — giao diện mô phỏng trực tiếp Antigravity dành cho iOS.

> Mở máy tính Windows ở nhà -> bật **WEP Host** -> cầm iPhone đi bất cứ đâu (Wi-Fi / 4G / 5G) vẫn có thể mở thư mục, sửa code trực tiếp, chạy terminal PowerShell và điều khiển AI Agent Antigravity theo thời gian thực.

---

## Tải Nhanh (Pre-built Releases)

- **Windows Gateway (`WEP.Host.exe`)**:
  - Tải trực tiếp trong repo: [`releases/WEP.Host.exe`](releases/WEP.Host.exe) *(Single-File ~1–3 MB, cần [.NET 9 Desktop Runtime](https://dotnet.microsoft.com/en-us/download/dotnet/9.0))*
  - Hoặc bản đầy đủ / **Releases**: [GitHub Releases (`latest`)](https://github.com/jaxcater/WEPRemote/releases/tag/latest)
- **iOS App (`WEP.ipa`)**:
  - Tải từ [GitHub Releases (`latest`)](https://github.com/jaxcater/WEPRemote/releases/download/latest/WEP.ipa)

---

## Phần 1 — Cài Đặt & Thiết Lập Trên Windows (`WEP.Host.exe`)

### Yêu cầu máy Windows ở nhà
1. **Windows 10 / 11 (64-bit)**.
2. **[.NET 9 Desktop Runtime (x64)](https://dotnet.microsoft.com/en-us/download/dotnet/9.0)** *(nếu chạy bản `WEP.Host.exe` trong `releases/` hoặc bản framework-dependent)*.
3. **Google Antigravity CLI (`agy.exe`)** đã cài và đăng nhập sẵn tại `%USERPROFILE%\.gemini\bin\agy.exe` (chạy thử `agy models` trong PowerShell để kiểm tra).
4. **Git** *(khuyến nghị cài sẵn để xem `Files Changed` & `Git Diff` trên iPhone)*.

### Các bước chạy WEP Host ở nhà
1. Tải [`releases/WEP.Host.exe`](releases/WEP.Host.exe) (hoặc giải nén bản ZIP trong GitHub Releases) vào một thư mục cố định, ví dụ `C:\WEP\WEP.Host.exe`.
2. Mở **`WEP.Host.exe`**:
   - Nếu Windows SmartScreen hiện cảnh báo *"Windows protected your PC"*, bấm **More info -> Run anyway**.
   - Nếu Windows Firewall hỏi quyền mạng, tích chọn cả **Private** và **Public/Domain** rồi bấm **Allow** để iPhone truy cập được qua LAN.
3. **Mở đường từ xa (Cloudflare Tunnel)**:
   - Bấm nút **Start Tunnel** ở cột bên trái.
   - Lần đầu tiên, WEP Host sẽ tự động tải `cloudflared.exe` về `%LOCALAPPDATA%\WEP\bin\cloudflared.exe` và mở một **Quick Tunnel** dạng `https://xxxx.trycloudflare.com`.
   - Khi thấy trạng thái `Tunnel: Connected` và đường link `trycloudflare.com` xuất hiện, **mã QR Pairing** bên dưới sẽ tự động cập nhật gồm cả **Tunnel URL + LAN URL + Access Token**.
4. **Cấu hình để máy ở nhà luôn sẵn sàng 24/7** *(trong tab `Gateway & Tunnel`)*:
   - **Keep PC awake while WEP Host is running**: Giữ máy không tự sleep khi đang treo WEP. *(Lưu ý: vẫn nên chỉnh Windows Power Settings -> "When plugged in, put my device to sleep after: Never" nếu treo qua đêm).*
   - **Launch WEP Host automatically when Windows starts**: Tự chạy khi bật máy/khởi động lại.
   - **Auto-open Cloudflare Tunnel on launch**: Tự bật đường hầm ngay khi mở app.
   - **Minimize to System Tray when closing window**: Bấm `X` sẽ thu xuống khay hệ thống thay vì tắt hẳn.
   - **Auto-approve Antigravity tool runs remotely**: Cho phép AI Agent tự chạy lệnh/sửa file từ xa không bị treo chờ xác nhận tay trên màn hình PC.
   - Bấm **Save & Apply Settings**.

### Mẹo: Dùng Domain cố định với Cloudflare Named Tunnel (tùy chọn)
Quick Tunnel (`trycloudflare.com`) rất tiện để dùng ngay nhưng mỗi lần tắt/bật lại PC sẽ đổi URL mới (cần quét lại QR hoặc dán URL mới). Nếu muốn **URL cố định mãi mãi**:
1. Tạo tài khoản Cloudflare miễn phí -> vào **Zero Trust -> Networks -> Tunnels -> Create a tunnel** (`Cloudflared`).
2. Copy **Tunnel Token** và gắn Public Hostname trỏ về `http://127.0.0.1:8420` (ví dụ `https://wep.tenmiencuaban.com`).
3. Trong `WEP.Host` -> tab **Gateway & Tunnel**:
   - Chọn **Cloudflare Tunnel Mode** = `Named Tunnel`.
   - Dán **Cloudflare Named Tunnel Token** và **Custom Public Domain**.
   - Bấm **Save & Apply Settings** -> **Stop Tunnel** -> **Start Tunnel**.

---

## Phần 2 — Cài Đặt App `WEP.ipa` Lên iPhone

File `WEP.ipa` được GitHub Actions biên dịch dạng **Unsigned / Ad-hoc** để bạn cài miễn phí không cần tài khoản Apple Developer $99/năm:

### Cách 1: Cài bằng Sideloadly (từ Windows, dễ nhất)
1. Tải **Sideloadly** trên Windows tại https://sideloadly.io và cài **iTunes** (bản non-Microsoft Store) + **iCloud** nếu chưa có.
2. Cắm iPhone vào PC qua cáp USB -> chọn **Trust This Computer** trên iPhone.
3. Kéo file `WEP.ipa` vào Sideloadly -> nhập Apple ID của bạn -> bấm **Start**.
4. Trên iPhone vào **Settings -> General -> VPN & Device Management** -> chọn Apple ID của bạn -> **Trust**.
5. Nếu iOS yêu cầu bật chế độ nhà phát triển: **Settings -> Privacy & Security -> Developer Mode -> ON** (khởi động lại iPhone).

### Cách 2: AltStore / SideStore / TrollStore
- **SideStore / AltStore**: Chọn `+` trong app trên iPhone và trỏ tới file `WEP.ipa` (hỗ trợ tự refresh chứng chỉ 7 ngày qua Wi-Fi).
- **TrollStore** *(nếu iOS hỗ trợ)*: Mở `WEP.ipa` bằng TrollStore để cài vĩnh viễn không hết hạn 7 ngày.

---

## Phần 3 — Ghép Nối & Sử Dụng Hàng Ngày Trên iPhone

1. Mở app **WEP** trên iPhone.
2. Chọn **Scan QR Code on WEP Host** -> đưa camera quét mã QR đang hiển thị trên cửa sổ `WEP Host` ở Windows.
   - *Mẹo*: App sẽ tự động kiểm tra **LAN URL** trước (nếu ở nhà cùng Wi-Fi cho tốc độ cực nhanh), và tự chuyển sang **Cloudflare Tunnel** khi bạn ra ngoài dùng 4G/5G.
3. **Các màn hình chính trên WEP iOS** (giao diện Antigravity):
   - **Agent (Chat Canvas)**:
     - Nhắn yêu cầu cho Antigravity như trên desktop.
     - Xem **Thought Process**, thẻ **Tool Execution** (`run_command`, `view_file`, `replace_file_content`,...), Markdown & code.
     - Bấm `@` để đính kèm file từ project Windows, `/` để chọn slash commands (`/plan`, `/fix`, `/review`, `/test`, `/explain`), đổi Model (`Gemini 4 Hydrogen`, `Gemini 4 Argon`, `Claude Opus/Sonnet 5.5`,...) và Mode (`Auto`, `Accept Edits`, `Plan`).
   - **Folders (Duyệt thư mục Windows)**:
     - Xem ổ đĩa `C:\`, `D:\`, tạo mới file/folder.
     - Bấm **Open This Folder in Antigravity** để chuyển workspace đang điều khiển.
   - **Code (Sửa code trực tiếp)**:
     - Chạm vào bất kỳ file mã nguồn nào để mở trình soạn thảo monospace có thanh ký tự lập trình (`{ } ( ) [ ] = ; / _`), chỉnh sửa và bấm **Save** để ghi trực tiếp xuống máy Windows.
   - **Terminal**:
     - Chạy lệnh PowerShell trực tiếp trong thư mục workspace trên PC (`git status`, `dotnet build`, `npm run dev`,...).
   - **Auxiliary Pane** *(icon bảng bên phải góc trên)*:
     - Xem **Files Changed** (`git status` + `git diff` tô màu xanh/đỏ) và **Tool Timeline**.

---

## Phần 4 — Tự Build Từ Mã Nguồn (Dành cho Developer)

### Build Windows Host
```powershell
# Chạy / build bản thường
dotnet build windows/WEP.Host/WEP.Host.csproj -c Release

# Đóng gói thành 1 file WEP.Host.exe duy nhất (cần .NET 9 Desktop Runtime)
dotnet publish windows/WEP.Host/WEP.Host.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o dist/single
```

### Build iOS `.ipa`
Workflow [.github/workflows/build-ipa.yml](.github/workflows/build-ipa.yml) tự chạy trên `macos-latest` mỗi khi push lên `main`:
1. Cài `xcodegen` và tạo `WEP.xcodeproj` từ `ios/WEP/project.yml`.
2. Compile `WEP.app` (`Release`, `iphoneos`, unsigned).
3. Đóng gói `Payload/WEP.app` thành `WEP.ipa` và publish lên **Artifacts** + **Releases (`latest`)**.

---

## Bảo mật khi mở máy ở nhà
- Mọi API và WebSocket (trừ `/api/health`) đều yêu cầu `Authorization: Bearer <token>` (so sánh constant-time).
- Nếu nghi ngờ lộ token hoặc mất điện thoại: bấm nút **Rotate** bên cạnh Access Token trong `WEP Host` để vô hiệu hóa toàn bộ phiên cũ ngay lập tức.
- Có thể giới hạn các thư mục được phép truy cập từ xa trong tab **Workspaces & Access** (`AllowedRoots`).
