#!/bin/bash


/home/pi/scripts/c_helpers/updateConfig ENTER_USERNAME ENTER_ACCESSCODE cloud.ardupilot.org /home/pi/drone_engage/de_comm/de_comm.config.module.json /home/pi/simulator/sim_de_mavlink_instances/de_comm.1.config.module.json /home/pi/simulator/sim_de_mavlink_instances/de_comm.2.config.module.json

/home/pi/scripts/wifi_start_ap.sh

sudo /home/pi/scripts/wifi_clean_all_non_ap.sh

/home/pi/scripts/sh_clean_logs.sh

# Clean up image files from de_camera folder
sudo find ~/drone_engage/de_camera -type f \( -iname "*.png" -o -iname "*.bmp" -o -iname "*.jpg" -o -iname "*.jpeg" \) -delete 2>/dev/null

# Delete all .bak files in drone_engage folder and subfolders
sudo find ~/drone_engage -type f -name "*.bak" -delete 2>/dev/null

