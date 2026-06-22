# FRC SystemCore on Raspberry Pi 5

Run [Limelight SystemCore OS](https://github.com/LimelightVision/systemcore-os-public) on a standard Raspberry Pi 5 Model B instead of the Compute Module 5 it was designed for.

## Quick Start


Thanks to netarcx (Trent) for original conversion to USB. See https://github.com/netarcx/systemcore-rpi5-guide

Claude was used extensively to work out the patches.

WSL was the Linux environment used


USB To Canbus adapter RH02 Plus (in bottom right USB slot)

Go to canable.io/updater/canable2.html and flash candlelight firmware to adapter

The Limelight Systemcore OS release name was changed in the build.sh file. Still release 10.


To build the image do


```bash
git clone https://github.com/icemannie/systemcore-rpi5-guide.git
cd systemcore-rpi5-guide
sudo ./build-image.sh
```

This produces `systemcore-pi5b-beta10-v1.img` — flash it to an SD card.

Insert the SD card into your Pi 5 and power on.



Connect to SYSTEMCORE WIFI - password PASSWORD

Limelight Hardware manager 2.07 Find Devices will show available Systemcore connections. Click one to open Systemcore main screen

Go to Configure and Update tab and set your team number

Set Ethernet address to 10.TE.AM.2 for ethernet connection

Return to Home tab and choose Terminal

```bash
echo "=== Patch 1/4: limelight_canbusprocess.service (fix unbalanced quote) ==="
tee /etc/systemd/system/limelight_canbusprocess.service << 'EOF'
[Unit]
Description=limelight_canbus
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'sleep 4 && \
  ip link set can_s0 type can bitrate 1000000 && \
  ip link set can_s0 txqueuelen 1000 && \
  ip link set can_s0 up && \
  ip link set can_s1 type can bitrate 1000000 && \
  ip link set can_s1 txqueuelen 1000 && \
  ip link set can_s1 up && \
  ip link set can_s2 type can bitrate 1000000 && \
  ip link set can_s2 txqueuelen 1000 && \
  ip link set can_s2 up && \
  ip link set can_s3 type can bitrate 1000000 && \
  ip link set can_s3 txqueuelen 1000 && \
  ip link set can_s3 up && \
  ip link set can_s4 type can bitrate 1000000 && \
  ip link set can_s4 txqueuelen 1000 && \
  ip link set can_s4 up'
Restart=on-failure
RestartSec=5
StartLimitInterval=0
StartLimitBurst=1000

[Install]
WantedBy=default.target
EOF
```

Make the changes in the file SystemcorePatches.txt - copy each of the 4 individually and paste into Terminal

When complete reboot using 

sudo systemctl daemon-reload
sudo reboot


Connect via radio or ethernet to 10.TE.AM.2

Create your own code using VSCode 2027 or use the examples at https://github.com/fondyfire2194/SystemcoreRPI5.git and download

The example has 2 Sparkmax (ID 20 and 24) and 1 Kraken (ID 10) code to use the CANbus adapter

Examples uses
•	Op Modes
•	V3 Commands
•	State machine


Open 2027 Driver Station and Elastic. Set adresses to 10.TE.AM.2

If you used our examples, there should be Teleop and Auto Opmodes available.

Canbus adapter lights should be flashing.

To avoid possible SC card corruption, always do a software shutdown sudo shutdown -h now before powering off the PI

Also from home screen, add package https://alpha.rhc2.revrobotics.com/download-site/debian/rev-robotics-rev-hardware-client-alpha_1.1.1_arm64.ipk to view can connected devices.



## Tested on

- Raspberry Pi 5 Model B (4GB/8GB)
- SystemCore Beta 10 (`limelightosr-beta-10`)
- Kernel: stock upstream 16K-page kernel (works on Pi 5B as-is since Beta 10)
- Host: WSL2 on Windows 11

## License

The kernel is licensed under GPL-2.0 (same as the Linux kernel). Boot configuration files and scripts are provided as-is.
