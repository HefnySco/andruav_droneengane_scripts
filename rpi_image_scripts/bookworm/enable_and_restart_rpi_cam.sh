#!/bin/bash
# enable_and_restart_rpi_cam.sh [service]
#
# Enables and starts one of the mutually-exclusive RPI camera modes:
#   de_camera_rpi_cam.service   -> plain camera capture (default)
#   de_camera_imx_ai.service    -> camera + Sony IMX500 hardware AI + tracker
#   de_camera_tracker.service   -> camera + software tracker
#   de_camera_teststream.service -> ffmpeg testsrc2 test stream only
#
# Only one of these can safely run at a time (they all drive the same
# physical camera / camera_manager_wrapper pipeline), so this script always
# disables and stops the other two before enabling and starting the
# requested one.

# Color definitions for terminal output
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

ALL_CAM_SERVICES=(de_camera_rpi_cam.service de_camera_imx_ai.service de_camera_tracker.service de_camera_teststream.service)

TARGET_SERVICE="${1:-de_camera_rpi_cam.service}"

valid=false
for s in "${ALL_CAM_SERVICES[@]}"; do
  [ "$s" = "$TARGET_SERVICE" ] && valid=true
done
if [ "$valid" != true ]; then
  echo -e "${RED}Unknown camera service: ${TARGET_SERVICE}${NC}"
  echo -e "${YELLOW}Usage: $0 [$(IFS='|'; echo "${ALL_CAM_SERVICES[*]}")]${NC}"
  exit 1
fi

echo -e "${YELLOW}Enabling and starting RPI Camera service: ${TARGET_SERVICE}...${NC}"

# Disable and stop any other camera mode first to avoid conflicting
# access to the camera/virtual-camera devices.
for s in "${ALL_CAM_SERVICES[@]}"; do
  if [ "$s" != "$TARGET_SERVICE" ]; then
    echo -e "${BLUE}Disabling and stopping ${s} (conflicting camera mode)...${NC}"
    sudo systemctl disable "$s" 2>/dev/null
    sudo systemctl stop "$s" 2>/dev/null
  fi
done

# Enable and start the requested service
echo -e "${BLUE}Enabling and starting ${TARGET_SERVICE}...${NC}"
if sudo systemctl unmask "$TARGET_SERVICE" && sudo systemctl enable "$TARGET_SERVICE" && sudo systemctl start "$TARGET_SERVICE"; then
  echo -e "${GREEN}${TARGET_SERVICE} enabled and started successfully.${NC}"
else
  echo -e "${RED}Failed to enable and start ${TARGET_SERVICE}.${NC}"
  exit 1
fi

echo -e "${GREEN}DE RPI Camera Capture service enabled and started.${NC}"

#User Info
echo -e "${YELLOW}This script enables and starts the following service:${NC}"
echo -e "${BLUE} - ${TARGET_SERVICE}${NC}"
echo -e "${YELLOW}These services are related to the Drone Engine system.${NC}"
