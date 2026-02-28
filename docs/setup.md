# XNav Setup Guide

## Hardware Requirements

- **Raspberry Pi Compute Module 4** (CM4) - as used in Limelight 3
  - 4GB RAM minimum recommended
  - 32GB eMMC or SD card
- **Camera**: ArduCam or Raspberry Pi Camera Module (CSI)
- **LED Ring Light**: 12V ring light with GPIO control (optional)
- **Network**: Ethernet connection to FRC robot network

---

## Installation Options

### Option A: Flash Pre-built ISO (Recommended)

1. Download the XNav `.img.xz` image
2. Flash to CM4 eMMC or SD card:

   **Using Raspberry Pi Imager:**
   - Open Raspberry Pi Imager
   - Choose "Use custom image" → select the `.img.xz` file
   - Select your storage device
   - Click Write

   **Using command line:**
   ```bash
   xzcat xnav-1.0.0.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
   ```

3. Insert into Limelight 3 hardware
4. Power on → wait ~2 minutes for first-boot installation
5. Access dashboard: **http://xnav.local:5800** or **http://10.TE.AM.11:5800**

---

### Option B: Install on Existing Raspberry Pi OS

1. Flash **Raspberry Pi OS Lite (64-bit)** to your device
2. SSH in or use keyboard/monitor
3. Clone the repository:
   ```bash
   git clone https://github.com/realaaravdas/Limelight3-XNav /opt/xnav-src
   ```
4. Run the setup script:
   ```bash
   sudo bash /opt/xnav-src/system/scripts/setup.sh
   ```
5. Reboot: `sudo reboot`
6. Access dashboard: **http://xnav.local:5800**

---

## Initial Configuration

### 1. Open the Dashboard

Navigate to `http://xnav.local:5800` (or the device's IP address on port 5800).

### 2. Configure Network

- Go to **Network** tab
- Enter your team number (e.g., `1234`)
- The NT server IP will auto-resolve to `10.TE.AM.2`
- Click **Save Network Settings**

### 3. Configure Camera

- Go to **Camera** tab
- Set resolution and FPS (default: 1280×720 @ 90fps)
- Adjust exposure (default: manual, exposure 100)
- Click **Save & Apply**

### 4. Calibrate Camera (Strongly Recommended for 3D accuracy)

- Print a **6×9 checkerboard** (inner corners), each square = 25mm
- Go to **Calibration** tab
- Set board rows/cols/square size to match your board
- Click **Start Collection**
- Hold the board in front of the camera at various angles/distances
- Wait for 20 frames to be collected (green corners = detected)
- Click **Compute** → wait for RMS error result (< 1.0 is good)

### 5. Upload Field Map (for robot pose estimation)

- Download the WPILib `.fmap` for the current season from:
  https://github.com/wpilibsuite/allwpilib or the FRC game manual
- Go to **Field Map** tab
- Click **Upload Field Map** → select your `.fmap` file
- Confirm tags are listed

### 6. Configure AprilTag Settings

- Go to **AprilTags** tab
- Set **Tag Family** to `tag36h11` (FRC 2024+)
- Set **Tag Size** to the physical tag size in meters (e.g., `0.1651` for 6.5")
- Click **Save & Apply**

---

## Usage During Competition

### Pre-match
1. Power on XNav
2. Confirm dashboard shows camera feed and tags being detected
3. Enable **Match Mode** in the dashboard for maximum performance

### Match Mode
Match Mode optimizes:
- CPU governor set to performance
- Reduced frame processing overhead
- Higher priority threads

Enable via dashboard or from robot code:
```cpp
m_vision.SetMatchMode(true);  // in AutonomousInit()
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Dashboard not accessible | Check IP address, ensure port 5800 is not blocked |
| No camera feed | Verify camera is connected, check `/dev/video0` exists |
| Tags not detecting | Check lighting, calibrate camera, verify tag family/size |
| Robot pose wrong | Upload correct .fmap, recalibrate camera |
| NT not connecting | Verify team number, check roboRIO is on same network |
| Low FPS | Enable match mode, reduce resolution, check CPU temperature |

---

## Network Ports

| Port | Service |
|------|---------|
| 5800 | Web dashboard (HTTP) |
| 5810 | NetworkTables 4 (NT4 server) |
| 1182 | MJPEG stream (optional) |

---

## LED Lights (Optional)

Connect a 12V LED ring light to GPIO pin 18 (default, configurable).
Use a PWM-capable MOSFET for brightness control.

Configure in the **Lights** tab of the dashboard.
