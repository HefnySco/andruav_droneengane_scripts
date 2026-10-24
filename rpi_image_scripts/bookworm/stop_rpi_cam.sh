#!/bin/bash
# stop_rpi_cam.sh
#
# Disables and stops all RPI camera mode services so none of them will
# start again on the next boot until explicitly re-enabled via
# enable_and_restart_rpi_cam.sh:
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

log_warn "Disabling and stopping all Drone Camera RPI services..."

for s in "${ALL_CAM_SERVICES[@]}"; do
  log_info "Stopping ${s}..."
  if sudo systemctl stop "$s" 2>/dev/null; then
    log_info "${s} stopped successfully."
  else
    log_error "Failed to stop ${s} (it may not have been running)."
  fi

  log_info "Disabling ${s}..."
  if sudo systemctl disable "$s" 2>/dev/null; then
    log_info "${s} disabled successfully."
  else
    log_error "Failed to disable ${s} (it may not have been enabled)."
  fi
done

#User Info
log_warn "This script stops and disables the following services:"
for s in "${ALL_CAM_SERVICES[@]}"; do
  log_info " - ${s}"
done
log_warn "These services are related to the Drone Engine system."
