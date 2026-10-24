#!/bin/bash

# Color definitions for terminal output
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Script to restart the DroneEngage GPIO module service

echo -e "${YELLOW}Restarting de_rpi_gpio.service...${NC}"

# Restart de_rpi_gpio.service
echo -e "${BLUE}Restarting de_rpi_gpio.service...${NC}"
if sudo systemctl restart de_rpi_gpio.service; then
  echo -e "${GREEN}de_rpi_gpio.service restarted successfully.${NC}"
else
  echo -e "${RED}Failed to restart de_rpi_gpio.service.${NC}"
fi

echo -e "${GREEN}de_rpi_gpio.service restarted.${NC}"

#User Info
echo -e "${YELLOW}This script restarts the following service:${NC}"
echo -e "${BLUE} - de_rpi_gpio.service${NC}"
echo -e "${YELLOW}This service runs the DroneEngage GPIO module.${NC}"
echo -e "${YELLOW}This does not change its AutoStart setting.${NC}"
