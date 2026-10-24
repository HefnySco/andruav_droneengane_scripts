#!/bin/bash
# restart_rpi_cam.sh
#
# Restarts whichever RPI camera mode service is currently active, without
# changing autostart settings. If none is active, it reports that and exits.
#   de_camera_rpi_cam.service, de_camera_imx_ai.service, de_camera_tracker.service,
#   de_camera_teststream.service

# Color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
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

ACTIVE_SERVICE=""
for s in "${ALL_CAM_SERVICES[@]}"; do
  if sudo systemctl is-active --quiet "$s" 2>/dev/null; then
    ACTIVE_SERVICE="$s"
    break
  fi
done

if [ -z "$ACTIVE_SERVICE" ]; then
  log_warn "No RPI camera mode service is currently running."
  log_warn "Use one of the Enable modes to start a camera mode first."
  exit 0
fi

log_warn "Restarting active RPI Camera service: ${ACTIVE_SERVICE} (autostart unchanged)..."

echo -e "${BLUE}Restarting ${ACTIVE_SERVICE}...${NC}"
if sudo systemctl restart "$ACTIVE_SERVICE"; then
  echo -e "${GREEN}${ACTIVE_SERVICE} restarted successfully.${NC}"
else
  echo -e "${RED}Failed to restart ${ACTIVE_SERVICE}.${NC}"
  exit 1
fi

#User Info
log_warn "This script restarts the following service (autostart is NOT changed):"
log_info " - ${ACTIVE_SERVICE}"
log_warn "These services are related to the Drone Engine system."
