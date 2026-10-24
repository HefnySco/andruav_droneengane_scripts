#!/bin/bash

# Color definitions for terminal output
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Wrapper that dispatches DroneEngage GPIO module (de_rpi_gpio) actions.
# Usage: de_gpio_control.sh {enable|restart|stop|disable}

ACTION="${1:-}"

case "$ACTION" in
    enable)
        echo -e "${YELLOW}Enable and start de_rpi_gpio...${NC}"
        exec /home/pi/scripts/enable_and_restart_de_gpio.sh
        ;;
    restart)
        echo -e "${YELLOW}Restart de_rpi_gpio...${NC}"
        exec /home/pi/scripts/restart_de_gpio.sh
        ;;
    stop)
        echo -e "${YELLOW}Stop de_rpi_gpio...${NC}"
        exec /home/pi/scripts/stop_de_gpio.sh
        ;;
    disable)
        echo -e "${YELLOW}Disable and stop de_rpi_gpio...${NC}"
        exec /home/pi/scripts/disable_de_gpio.sh
        ;;
    *)
        echo -e "${RED}Unknown action: '${ACTION}'${NC}"
        echo -e "${YELLOW}Usage: de_gpio_control.sh {enable|restart|stop|disable}${NC}"
        exit 1
        ;;
esac
