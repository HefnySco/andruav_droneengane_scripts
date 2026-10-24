#!/bin/bash

# Color definitions for terminal output
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Script to disable and stop the DroneEngage GPIO module service

echo -e "${YELLOW}Disabling de_rpi_gpio.service...${NC}"

# Disable de_rpi_gpio.service
echo -e "${BLUE}Disabling de_rpi_gpio.service...${NC}"
if sudo systemctl disable de_rpi_gpio.service; then
  echo -e "${GREEN}de_rpi_gpio.service disabled successfully.${NC}"
else
  echo -e "${RED}Failed to disable de_rpi_gpio.service.${NC}"
fi

echo -e "${GREEN}de_rpi_gpio.service disabled.${NC}"

#User Info
echo -e "${YELLOW}This script disables the following service:${NC}"
echo -e "${BLUE} - de_rpi_gpio.service${NC}"
echo -e "${YELLOW}This service runs the DroneEngage GPIO module.${NC}"

#Stop the service if it is currently running.
echo -e "${YELLOW}Stopping the service if it is currently running...${NC}"

# Stop de_rpi_gpio.service
echo -e "${BLUE}Stopping de_rpi_gpio.service...${NC}"
if sudo systemctl stop de_rpi_gpio.service; then
  echo -e "${GREEN}de_rpi_gpio.service stopped successfully.${NC}"
else
  echo -e "${RED}Failed to stop de_rpi_gpio.service.${NC}"
fi

echo -e "${GREEN}de_rpi_gpio.service is now disabled and stopped.${NC}"
