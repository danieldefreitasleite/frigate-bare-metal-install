Here is the **README.md** file, streamlined to describe the solution without embedding large blocks of code or YAML configuration files, preventing rendering issues.

***

# Frigate NVR - Bare Metal LXC Installer (Debian 12)

This repository contains a specialized Bash script designed to install **Frigate NVR** directly onto a **Debian 12 (Bookworm) LXC container** (specifically for Proxmox users) without the overhead or complexity of Docker.

It replicates the robust internal architecture of the official Frigate Docker image (using **S6-Overlay** for process supervision) but adapts it to run natively on the host OS. This approach maximizes hardware compatibility (Google Coral, iGPU) and performance while maintaining the stability of the official release.

## 🚀 Objectives & Technical Achievements

The script was developed to solve specific challenges associated with running Frigate outside of Docker. It handles the following:

*   **Native Execution:** Runs Frigate, Nginx, and Go2RTC using system binaries and a Python Virtual Environment (`venv`).
*   **S6-Overlay Adaptation:** Imports the official service supervision tree but patches it to work on a bare metal system (removing Docker-specific initialization steps and wrappers).
*   **Memory Optimization:** Installs and configures `libjemalloc2` via `LD_PRELOAD`. This is critical for preventing memory fragmentation and buffer overflows during high-bandwidth recording, solving common "static frame" or "stuck recording" issues.
*   **Hardware Acceleration:** Automatically compiles `libusb` from source to ensure perfect compatibility with Google Coral EdgeTPU devices and configures permissions for Intel/Nvidia GPUs.
*   **Zombie cameras cache Management:** Implements a custom cleanup routine triggered by Systemd to clean up /tmp/cache corruption when restarting the service.
*   **Context Repair:** Fixes directory context issues that typically cause migration scripts or recording segments to fail in non-Docker environments.

## ⚠️ Prerequisites

Before running the installer, ensure your LXC container meets these requirements:

1.  **OS:** Debian 12 (Bookworm) - Unprivileged LXC.
2.  **RAM:** Minimum 2GB (4GB recommended during installation for compiling assets).
3.  **Shared Memory (/dev/shm):** Standard LXC containers default to 64MB, which is insufficient for Frigate. You **must** increase this in your Proxmox container configuration file to at least 1GB (1024MB) to accommodate raw video buffers.
4.  **Hardware Passthrough:** Ensure your Coral USB and/or GPU devices are passed through to the container.

## 🛠️ Installation Usage

1.  Download the **frigate-bare-metal-install.sh** script to your LXC root directory.
2.  Give the script execution permissions.
3.  Run the script as **root**.

### Interactive Menu Options
During the installation process, you will be prompted to choose:
*   **Frigate Version:** Choose between the latest Stable release or the latest Beta/RC.
*   **Authentication:** Enable or disable Frigate's built-in web authentication.
Below is commented in the code but available if needed:
*   **Configuration Strategy:** 
    *   **Clean Install (Recommended):** Generates a blank configuration file. This is the safest option to prevent database corruption caused by "Test Camera" artifacts.
    *   **Demo Mode:** Installs a looped sample video for testing purposes.

## ⚙️ Configuration & Maintenance

### Configuration File
The configuration file is stored at `/etc/frigate/config.yaml`. The system also maintains a compatibility symlink at `/config/config.yaml`.

### Addressing "Error 461: Unsupported Transport"
If your logs show Error 461, it means your camera is rejecting UDP connections. To fix this:
1.  Configure **Go2RTC** streams to use the native RTSP client and append the TCP suffix to the URL.
2.  Configure **Frigate** camera inputs to use the `preset-rtsp-restream` argument, which forces FFmpeg to use TCP.

### Service Management
The application is managed by a Systemd unit named `frigate-s6`.
*   **To Start/Restart:** Use standard `systemctl` commands. This will trigger the necessary environment preparation and cleanup scripts automatically.
*   **To Stop:** Stopping the service triggers a post-stop cleanup to ensure no processes remain running.

## 📂 File Paths Reference

*   **Service Definition:** `/etc/systemd/system/frigate-s6.service`
*   **Application Source:** `/opt/frigate/repo`
*   **Web Interface Assets:** `/opt/frigate/web_dist`
*   **Recordings & Storage:** `/media/frigate`
*   **Config:** `/media/frigate/config`
*   **Database:** `/opt/frigate/database`
*   **Logs:** `/var/log/frigate_install.log` (Install logs) and Systemd Journal (Runtime logs).
*   **Cache:** `/tmp/cache` (Mounted as RAM disk).

## Credits
This project is an adaptation of the official Frigate NVR project by Blake Blackshear, modified for bare-metal performance and stability.
