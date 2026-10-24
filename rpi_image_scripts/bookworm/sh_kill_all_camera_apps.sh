#!/bin/bash

# Define color codes
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

echo "Killing Camera Apps"

echo -e "${RED}KILLING Camera Related APPs.${NC}"

# Never kill our own ancestor chain: camera_manager_wrapper invokes this
# script during startup, and a bare `pkill -f camera_manager_wrapper` would
# SIGKILL the caller itself (and `sudo pkill -f X` self-matches its own
# sudo cmdline). Still kills other stale instances as intended.
kill_matching() {
    local pattern="$1"
    local pid ancestor skip
    local ancestors=""
    ancestor=$PPID
    while [ -n "$ancestor" ] && [ "$ancestor" -gt 1 ] 2>/dev/null; do
        ancestors="$ancestors $ancestor"
        ancestor=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d ' ')
    done
    for pid in $(pgrep -f "$pattern"); do
        skip=0
        for ancestor in $$ $ancestors; do
            if [ "$pid" = "$ancestor" ]; then skip=1; break; fi
        done
        [ "$skip" = "1" ] || sudo kill -9 "$pid" 2>/dev/null
    done
}

kill_matching de_yolo_generic
kill_matching rpicam-vid
kill_matching de_tracker
kill_matching de_perceive
kill_matching de_yolo_generic_rknn
kill_matching de_camera
kill_matching camera_manager_wrapper
kill_matching ffmpeg
kill_matching sh_camera_run_gimbal_camera.sh
kill_matching sh_camera_run_test_stream.sh
kill_matching ffplay

# fix screen (may run without a tty when invoked by camera_manager_wrapper)
stty sane 2>/dev/null || true
