# Building XNav in Google Colab

This guide explains how to build a flashable XNav `.img.xz` image entirely inside a **Google Colab** notebook—no local Linux machine, WSL, or root access required.

The Colab-specific build script (`colab_build.sh`) replaces all `losetup`, `mount`, and `modprobe` calls with **guestfish** (from `libguestfs-tools`), which manipulates disk images in userspace. This makes the build compatible with Colab's containerised runtime.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **Google account** | Free tier works, but Colab Pro gives longer runtimes |
| **Runtime type** | Default CPU runtime (no GPU needed) |
| **Disk space** | ≥ 10 GB free (default Colab provides ~80 GB) |
| **Internet** | Required to download the base Raspberry Pi OS image (~500 MB) |
| **Build time** | ~30–60 minutes depending on network and compression speed |

> **Tip:** For the best experience use a **Colab Pro** runtime to avoid idle disconnects during the build.

---

## Step 1 — Open a New Colab Notebook

Go to [https://colab.research.google.com](https://colab.research.google.com) and create a **New notebook**.

---

## Step 2 — Clone the Repository

In the first code cell run:

```python
!git clone https://github.com/realaaravdas/Limelight3-XNav.git /content/Limelight3-XNav
%cd /content/Limelight3-XNav
```

---

## Step 3 — Download the Base Raspberry Pi OS Image

The build script downloads the image automatically, but you can pre-download it to avoid re-downloading if the cell restarts:

```python
import os, subprocess

work_dir = "/tmp/xnav-build"
os.makedirs(work_dir, exist_ok=True)

base_img = os.path.join(work_dir, "raspios_lite_arm64_latest.img.xz")
if not os.path.exists(base_img):
    print("Downloading Raspberry Pi OS Lite (64-bit) — this takes ~5 minutes...")
    subprocess.run([
        "wget", "-q", "--show-progress",
        "-O", base_img,
        "https://downloads.raspberrypi.org/raspios_lite_arm64_latest"
    ], check=True)
    print("Download complete.")
else:
    print("Base image already downloaded.")
```

---

## Step 4 — Run the Build Script

```python
!bash system/scripts/colab_build.sh
```

The script will:

1. Install `libguestfs-tools`, `qemu-utils`, and other required packages (non-interactive, `-y`)
2. Decompress and copy the base Raspberry Pi OS image
3. Expand the image by 512 MB
4. Resize the root filesystem with `guestfish`
5. Stage all XNav files (web dashboard, C++ source, config, services)
6. Download Bootstrap CSS/JS for the offline web dashboard
7. Inject everything into the image via `guestfish` (`copy-in`, `upload`, `ln-sf`, etc.)
8. Set hostname to `xnav`, configure boot parameters, and enable systemd services
9. Compress the final image with `xz -9` (~10–20 minutes)

### Expected output

```
[COLAB-BUILD] XNav Colab ISO Builder v1.1.0 (C++ edition)
[COLAB-BUILD] Installing required packages...
[COLAB-BUILD] Downloading base Raspberry Pi OS Lite (64-bit)...
[COLAB-BUILD] Expanding image by 512 MB...
[COLAB-BUILD] Resizing root filesystem...
[COLAB-BUILD] Preparing staging area...
[COLAB-BUILD] Downloading Bootstrap vendor assets...
[COLAB-BUILD] Injecting files into image via guestfish...
[COLAB-BUILD] File injection complete.
[COLAB-BUILD] Compressing image (this may take 10-20 minutes)...
[COLAB-BUILD] ═══════════════════════════════════════════
[COLAB-BUILD]   Build complete: /tmp/xnav-build/xnav-1.1.0.img.xz
[COLAB-BUILD] ═══════════════════════════════════════════
```

---

## Step 5 — Save the Output to Google Drive

Mount your Google Drive and copy the finished image so it survives runtime disconnection:

```python
from google.colab import drive
import shutil

# Mount Google Drive (will prompt for authorization)
drive.mount('/content/drive')

# Copy the built image to Google Drive
src = "/tmp/xnav-build/xnav-1.1.0.img.xz"
dst = "/content/drive/MyDrive/xnav-1.1.0.img.xz"

print(f"Copying {src} → {dst} ...")
shutil.copy2(src, dst)
print("Done! Image saved to Google Drive.")
```

You can then download it from Google Drive on any machine for flashing.

---

## Step 6 — Flash the Image

Download `xnav-1.1.0.img.xz` from Google Drive to your local machine and flash it using one of these methods:

### Option A: balenaEtcher (recommended)

1. Download [balenaEtcher](https://etcher.balena.io/)
2. **Flash from file** → select `xnav-1.1.0.img.xz`
3. **Select target** → choose the Limelight 3 eMMC / SD card
4. **Flash!**

### Option B: Command line (Linux)

```bash
xzcat xnav-1.1.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with the correct target device.

### Option C: Raspberry Pi Imager

1. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. **Operating System** → **Use custom** → select `xnav-1.1.0.img.xz`
3. **Storage** → select the target drive
4. Click **Write**

---

## Step 7 — First Boot

1. Connect the Limelight 3 to your robot network via Ethernet
2. Apply power
3. On first boot the device will automatically compile the C++ binary (~5–10 min, requires internet)
4. After compilation finishes, the XNav vision service starts automatically
5. Open a browser and navigate to:
   - `http://xnav.local:5800` (mDNS)
   - or `http://10.TE.AM.11:5800` (replace `TE.AM` with your team number)

> **Note:** Because Google Colab cannot cross-compile ARM64 binaries via QEMU chroot, the C++ binary is compiled on the device during first boot. Subsequent boots start instantly.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `guestfish` hangs or crashes | Ensure `linux-image-generic` is installed (the script does this automatically). Try restarting the Colab runtime. |
| Download fails | Download the Raspberry Pi OS image manually and upload it to `/tmp/xnav-build/raspios_lite.img` |
| Colab disconnects during build | Use **Colab Pro** for longer runtimes, or pre-download the base image (Step 3) and re-run |
| `libguestfs` "supermin" errors | The script sets `LIBGUESTFS_BACKEND=direct` and `force_tcg` automatically for containerised environments |
| Image too large for Google Drive free tier | The compressed image is ~350–500 MB; ensure you have enough Drive quota |
| First-boot compile fails on device | SSH into the Pi and run `sudo bash /opt/xnav/build_on_device.sh` manually |

---

## How It Differs from the Standard Build

| Aspect | `build_iso.sh` | `colab_build.sh` |
|--------|----------------|-------------------|
| **Loop devices** | `losetup -fP --show` | Not used |
| **Mounting** | `mount` (kernel) | `guestfish` (userspace) |
| **Kernel modules** | Requires `modprobe loop` | No kernel modules needed |
| **ARM64 chroot** | QEMU chroot cross-compile | Skipped; compiles on-device |
| **Root required** | Yes (`sudo`) | Only for `apt-get install` |
| **Environment** | Linux / WSL2 | Google Colab, Docker, CI containers |
| **Pre-compiled binary** | Yes | No (compiled on first boot) |
| **First-boot delay** | None | ~5–10 min (one-time compile) |
