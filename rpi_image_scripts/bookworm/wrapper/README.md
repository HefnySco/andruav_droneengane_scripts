# Camera Manager Wrapper

This folder contains a C++ wrapper application for managing DroneEngage camera and tracking modules on Raspberry Pi. The wrapper orchestrates the startup, monitoring, and graceful shutdown of multiple camera-related processes.

## Files

- **camera_manager_wrapper.cpp**
  C++ source code for the camera manager wrapper. Compiles to a single binary that manages the lifecycle of camera pipelines and tracking modules. `camera_manager_wrapper_ubuntu.cpp` is the same source for desktop/Ubuntu builds.

- **camera_manager_wrapper**
  Compiled binary (built with `g++ camera_manager_wrapper.cpp -o camera_manager_wrapper -pthread`).

## Features (v5)

- **Process Management**: Forks and monitors child processes for camera pipelines (`rpicam-vid | ffmpeg` fan-out, gimbal RTSP, test stream) and modules (`de_perceive`, `de_tracker`, `de_camera`).
- **Producer fan-out** (TASK-03 topology): one `rpicam-vid | ffmpeg` producer writes one `-f v4l2` output per consumer device — `DE-RPI` for de_camera plus the resolved input device of each enabled consumer (`de_perceive`, `de_tracker`). v4l2loopback devices are single-consumer (`exclusive_caps=1`), so each consumer gets its own device.
- **de_perceive backends**: `-p <backend>` selects the perception backend (`onnx`, `rknn`, `hailo`, `imx500_udp`) instead of the old `-a`/`-g` AI-tracker flags. `-t` now means the lock-on-only `de_tracker`.
- **Readiness instead of sleeps**: fixed startup delays are gone. The wrapper waits until each producer output device actually has a producer attached before starting the consumers, and waits for each module to survive an alive-window before starting the next.
- **Per-module restart with backoff**: a crashed child is restarted alone (exponential backoff 2s→30s, cap `--max-restarts`, default 5). The whole stack only exits after one child exceeds its restart budget, letting systemd restart it.
- **Config device validation**: before starting anything, every enabled module's `source_video_device[_name]` / `output_video_device[_name]` (and de_camera `camera_list` entries) must resolve to an existing `/dev/video*` — a stale name like `SIM-CAM1` aborts startup with a message naming the module and the device.
- **Process-group shutdown**: every child is a process-group leader; `kill(-pid)` takes pipelines (sh + rpicam-vid + ffmpeg) down together, with SIGKILL fallback after a grace window.
- **Virtual Camera Setup**: Automatically loads `v4l2loopback` kernel module to create named virtual cameras (`DE-CAM1`, `DE-CAM2`, `DE-TRK`, `DE-RPI`, `DE-THERMAL`, `DE-AI`, `DE-GIMBAL`, `test_stream`).
- **Preemptive Cleanup**: Kills any stale camera processes before starting new instances to prevent conflicts.
- **Custom Script Execution**: Supports running additional scripts via `--execute` option.
- **Configurable Paths**: Supports custom DroneEngage and scripts paths via command-line arguments.

## Usage

```bash
./camera_manager_wrapper [OPTIONS] [postprocess_file_path]
```

### Options

| Option | Description |
|--------|-------------|
| `-c`, `--enable-rpi-cam-capture` | Enable Raspberry Pi camera capture pipeline (fan-out to consumer devices) |
| `-t`, `--enable-tracker` | Enable `de_tracker` lock-on tracker (consumes `obs` from de_perceive) |
| `-p`, `--perceive-backend <b>` | Start `de_perceive` with backend `onnx`\|`rknn`\|`hailo`\|`imx500_udp` |
| `-d`, `--disable-de-camera` | Disable `de_camera` module (enabled by default) |
| `-e`, `--execute <script>` | Execute a custom script (can be specified multiple times) |
| `-D`, `--drone-engage-path <path>` | Custom DroneEngage modules path (default: `/home/pi/drone_engage/`) |
| `-S`, `--scripts-path <path>` | Custom scripts path (default: `/home/pi/scripts/`) |
| `-m`, `--enable-gimbal-capture` | Enable gimbal RTSP camera capture pipeline |
| `-s`, `--enable-test-stream` | Enable `test_stream` ffmpeg testsrc2 pipeline; `de_camera` uses `de_camera.config.module.teststream.json` |
| `--readiness-timeout <sec>` | Wait limit for a producer to attach to a device (default: 30s) |
| `--module-alive <sec>` | Alive-window a module must survive during startup (default: 5s) |
| `--max-restarts <n>` | Per-child restart budget before the stack exits (default: 5) |
| `-v`, `--version` | Print version and exit |
| `-h`, `--help` | Print usage and exit |

Removed in v5: `-a`/`--enable-ai-tracker` (de_ai_tracker), `-g`/`--enable-generic-ai-tracker` (de_yolo_generic) and all fixed-delay options (`-A`, `-G`, `-T`, `-C`, `-M`). Use `-p <backend>` for perception and `-t` for the lock-on tracker.

### Examples

#### **RPi camera only**
```bash
./camera_manager_wrapper --enable-rpi-cam-capture
```
- **Used by**: `de_camera_rpi_cam.service`

#### **RPi camera + ONNX perception + lock-on tracker**
```bash
./camera_manager_wrapper --enable-rpi-cam-capture --perceive-backend onnx --enable-tracker
```
- Producer fans out to `DE-RPI` (de_camera) + the `source_video_device[_name]` from `de_perceive.config.module.json` + the tracker input device.
- **Used by**: `de_camera_perceive.service`

#### **IMX500 hardware AI (UDP detections) + lock-on tracker**
```bash
./camera_manager_wrapper --enable-rpi-cam-capture --perceive-backend imx500_udp -t "/usr/share/rpi-camera-assets/imx500_mobilenet_ssd.json"
```
- The positional JSON is the rpicam-vid `--post-process-file` that runs inference on the IMX500 sensor; `de_perceive` receives detections over UDP (no video device needed).
- **Used by**: `de_camera_imx_ai.service`

#### **RKNN (Rockchip NPU)**
```bash
./camera_manager_wrapper --enable-rpi-cam-capture --perceive-backend rknn --enable-tracker
```
- Runs the `de_yolo_generic_rknn` binary with `de_yolo_ai_generic_rknn.config.module.json`.

#### **Gimbal Camera Pipeline**
```bash
./camera_manager_wrapper --enable-gimbal-capture
```
- **Used by**: `de_camera_gimbal.service`

#### **Test Stream (Synthetic Camera)**
```bash
./camera_manager_wrapper --enable-test-stream
```
- **Used by**: `de_camera_teststream.service`

#### **Custom Paths**
```bash
./camera_manager_wrapper --drone-engage-path /custom/de/path --scripts-path /custom/scripts --enable-rpi-cam-capture
```

## Module Paths

The wrapper expects DroneEngage modules at the following locations (default paths, configurable via arguments):

| Module | Default Path |
|--------|--------------|
| `de_camera` | `/home/pi/drone_engage/de_camera/` |
| `de_tracker` | `/home/pi/drone_engage/de_tracking/` |
| `de_perceive` | `/home/pi/drone_engage/de_perceive/` (falls back to `de_yolo_generic/`) |

Backend → binary/config mapping for `-p`:

| Backend | Binary | Config |
|---------|--------|--------|
| `onnx` | `de_perceive` | `de_perceive.config.module.json` (or `de_perceive.config.module.onnx.json` if present) |
| `hailo` | `de_perceive` | `de_perceive.config.module.hailo.json` or default |
| `imx500_udp` | `de_perceive` | `de_perceive.config.module.imx500_udp.json` or default |
| `rknn` | `de_yolo_generic_rknn` | `de_yolo_ai_generic_rknn.config.module.json` |

When the chosen config contains a `"backend"` key it must equal the `-p` value.

## Build

```bash
g++ camera_manager_wrapper.cpp -o camera_manager_wrapper -pthread
```

---

## Version

Current version: **5.0.0**

---

## Notes

- Requires `sudo` for killing processes and loading kernel modules.
- Expects helper scripts in `/home/pi/scripts/` (configurable via `--scripts-path`):
  - `sh_camera_create_named_vc.sh`
  - `sh_kill_all_camera_apps.sh`
  - `sh_camera_run_gimbal_camera.sh`
  - `sh_camera_run_test_stream.sh`
- The rpicam-vid pipeline is built inline (matching `sh_camera_run_rpi_camera.sh` defaults: 1920x1080@15, yuv420, `--nopreview --vflip=1`) so it can fan out to several loopback devices.
- Designed to run as a systemd service for automatic restart on failure.
- Uses Unix `fork()`/`execlp()` for direct process control; every child is a process-group leader.
