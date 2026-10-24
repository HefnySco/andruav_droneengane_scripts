#!/bin/bash
# stop_rpi_cam_only.sh
#
# Stops all RPI camera mode services without disabling them, so they will
# resume on the next reboot if autostart is enabled:
#   de_camera_rpi_cam.service, de_camera_imx_ai.service, de_camera_tracker.service,
#   de_camera_teststream.service

# Color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

ALL_CAM_SERVICES=(de_camera_rpi_cam.service de_camera_imx_ai.service de_camera_tracker.service de_camera_teststream.service)

log_warn "Stopping all Drone Camera RPI services (autostart unchanged)..."

for s in "${ALL_CAM_SERVICES[@]}"; do
  log_info "Stopping ${s}..."
  if sudo systemctl stop "$s" 2>/dev/null; then
    log_info "${s} stopped successfully."
  else
    log_error "Failed to stop ${s} (it may not have been running)."
  fi
done

#User Info
log_warn "This script stops the following services (autostart is NOT changed):"
for s in "${ALL_CAM_SERVICES[@]}"; do
  log_info " - ${s}"
done
log_warn "These services are related to the Drone Engine system."
