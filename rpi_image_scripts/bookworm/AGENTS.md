# AGENTS.md — RPi Image Scripts (Bookworm)

Shell scripts and helpers for Raspberry Pi (Bookworm, 64-bit) image setup,
camera pipeline, WiFi/AP management, DroneEngage service control, and OEM
image preparation. These scripts live on the Pi under `/home/pi/scripts/`
and are sourced from this repository for distribution.

## Layout

- `wrapper/` — `camera_manager_wrapper` (C++ binary + source). Orchestrates
  the full camera pipeline: rpicam-vid → ffmpeg → v4l2loopback, plus
  optional tracker, AI tracker, gimbal, and de_camera modules.
- `service/` — systemd unit files for DroneEngage modules and camera services.
- `updates/` — OTA deployment helpers (`sh_deploy_modules.sh`,
  `sh_backup_configurations.sh`, `sh_list_versions.sh`).
- `c_helpers/` — `updateConfig` C helper for OEM credential reset.
- `not_used_but_useful/` — archived/legacy scripts.

## WiFi / AP Management

- `wifi_start_ap.sh` — Creates a NetworkManager hotspot `DE_ADMIN`
  (password `droneengage`, AP `192.169.9.1/24`). Stops hostapd/dnsmasq
  to avoid conflicts.
- `wifi_use_wlan.sh <SSID> <Password>` — Switches from AP mode to a
  client WiFi connection. Deletes the hotspot, creates a new NM
  connection profile, and activates it.
- `wifi_clean_all_non_ap.sh` — Deletes all NM connections except `hotspot`.
- `service/check-and-run.service` — On boot, checks for
  `/boot/firmware/activate_ap.txt`; if present, starts AP mode and
  removes the flag file.

### Headless WiFi Connection Fix

On headless Pis (no desktop/GNOME keyring), NetworkManager has no secret
agent running. When `nmcli con up` tries to activate a WiFi connection,
NM cannot provide the stored PSK to wpa_supplicant — it fails with
"No agents were available for this request."

`wifi_use_wlan.sh` works around this by using `nmcli con up <name>
passwd-file <file>` to pass the PSK directly at activation time, bypassing
the secret agent. A temporary file is created via `mktemp`, contains one
line (`802-11-wireless-security.psk=<password>`), and is deleted on script
exit via a `trap`.

## Camera Pipeline

- `sh_camera_run_rpi_camera.sh [postprocess_file]` — Streams from RPi
  camera via `rpicam-vid` → `ffmpeg` → v4l2loopback virtual camera
  (`DE-RPI`). Uses `--nopreview` to disable on-screen display and save
  GPU/CPU resources on headless operation. Optionally attaches a
  post-processing JSON (e.g., IMX500 MobileNet SSD).
- `sh_camera_create_named_vc.sh` — Loads `v4l2loopback` with 8 named
  virtual cameras (DE-CAM1, DE-CAM2, DE-TRK, DE-RPI, DE-THERMAL, DE-AI,
  DE-GIMBAL, test_stream).
- `sh_kill_all_camera_apps.sh` — Kills rpicam-vid, de_tracker,
  de_ai_tracker, de_camera, de_yolo_generic processes.
- `sh_camera_run_gimbal_camera.sh` — Gimbal RTSP → ffmpeg → v4l2loopback.
- `sh_camera_run_test_stream.sh` — ffmpeg `testsrc2` pattern →
  v4l2loopback virtual camera `test_stream` (synthetic test feed).
- `sh_camera_senxor_thermal_run_on_vc.sh` — Thermal sensor pipeline.

### Kernel Note (IMX500)

Kernel `6.12.75+rpt-rpi-v8` broke the IMX500 camera via the
`bcm2835_unicam_legacy` driver (`stream on failed in subdev`). Pin to
kernel `6.12.34+rpt-rpi-v8` in `/boot/firmware/config.txt`:

```
[all]
kernel=vmlinuz-6.12.34+rpt-rpi-v8
initramfs initrd.img-6.12.34+rpt-rpi-v8 followkernel
```

And hold the kernel package: `sudo apt-mark hold raspberrypi-kernel`.

## OEM Image Preparation

- `hlp_reset_oem.sh` — Resets credentials to placeholders, starts AP
  mode, cleans WiFi profiles, runs `sh_clean_logs.sh`, deletes camera
  images and `.bak` files.
- `sh_clean_logs.sh` — Sanitizes image for distribution: clears journals,
  logs, history, temp files, apt cache, old kernels, SSH host keys,
  `~/.ssh/*`, `*.local` files, and config backups. **Destructive** — do
  not run on a production Pi. If run over SSH, it will kill the session
  at step 9 (SSH host key regeneration).
- `sh_reset_config_local_files.sh` — Deletes `*.local` instance identity
  files from `/home/pi/drone_engage/`.

## Service Control

### Core Services (de_communicator, de_mavlink, de_camera)

- `de_service_control.sh {enable|restart|stop|disable}` — Wrapper that
  dispatches collective DroneEngage service actions.
- `enable_and_restart_services.sh` — Enables and starts all DroneEngage
  systemd services (unmasks first).
- `disable_droneengage_service.sh` — Stops and disables all services.
- `restart_droneengage_services.sh` — Restarts all services.
- `stop_droneengage_services.sh` — Stops all services (autostart unchanged).

### RPI Camera (`de_camera_*`)

- `de_cam_control.sh {<camera_service>|restart|stop|disable}` — Wrapper
  that dispatches RPI camera actions. Enabling a mode stops and disables
  any other camera mode first (only one can run at a time). Modes:
  `de_camera_rpi_cam.service`, `de_camera_imx_ai.service`,
  `de_camera_tracker.service`, `de_camera_teststream.service`
  (`camera_manager_wrapper -s` — runs only the `test_stream` ffmpeg feed
  and `de_camera` with `de_camera.config.module.teststream.json`).
- `enable_and_restart_rpi_cam.sh [service]` — Enables and starts one
  camera mode, disabling conflicting modes first.
- `restart_rpi_cam.sh` — Restarts the currently active camera mode
  (autostart unchanged).
- `stop_rpi_cam_only.sh` — Stops all camera modes (autostart unchanged,
  resume on reboot).
- `stop_rpi_cam.sh` — Stops and disables all camera modes.

### Sound (`de_snd`)

- `de_snd_control.sh {enable|restart|stop|disable}` — Wrapper that
  dispatches de_snd actions.
- `enable_and_restart_de_snd.sh` — Enables and starts de_snd.
- `restart_de_snd.sh` — Restarts de_snd (autostart unchanged).
- `stop_de_snd.sh` — Stops de_snd (autostart unchanged, resume on reboot).
- `disable_de_snd.sh` — Stops and disables de_snd.

### GPIO (`de_rpi_gpio`)

- `de_gpio_control.sh {enable|restart|stop|disable}` — Wrapper that
  dispatches de_rpi_gpio actions.
- `enable_and_restart_de_gpio.sh` — Enables and starts de_rpi_gpio.
- `restart_de_gpio.sh` — Restarts de_rpi_gpio (autostart unchanged).
- `stop_de_gpio.sh` — Stops de_rpi_gpio (autostart unchanged, resume on
  reboot).
- `disable_de_gpio.sh` — Stops and disables de_rpi_gpio.

### Telnet (`de_telnet`)

- `de_telnet_control.sh {enable|restart|stop|disable}` — Wrapper that
  dispatches de_telnet actions. WARNING: de_telnet exposes a remote
  terminal on the DroneEngage bus — restrict access via `allowed_users`
  in the config file.
- `enable_and_restart_de_telnet.sh` — Enables and starts de_telnet.
- `restart_de_telnet.sh` — Restarts de_telnet (autostart unchanged).
- `stop_de_telnet.sh` — Stops de_telnet (autostart unchanged, resume on
  reboot).
- `disable_de_telnet.sh` — Stops and disables de_telnet.

### MAVLink Config Helper

- `de_mavlink_config_helper.py` — Python helper used by the Cockpit
  `de_plugin_mavlink_configurator` to read/write de_mavlink FCB
  connection and MAVLink ID settings.

## Simulators

- `sh_start_simulators.sh` — Starts SITL simulator instances.
- `sh_stop_simulators.sh` — Stops simulators.
- `sh_update_de_comm_config_in_sim.sh` — Updates de_comm config for sim.

## Conventions

- Scripts use `sudo nmcli` for all network operations (NetworkManager
  managed).
- WiFi connection names follow the pattern `Wifi_<SSID>_Conn`.
- The AP connection is always named `hotspot`.
- All scripts are POSIX-compatible bash; no bashisms beyond arrays.
