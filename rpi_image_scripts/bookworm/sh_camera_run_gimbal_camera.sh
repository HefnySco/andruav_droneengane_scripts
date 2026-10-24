#!/bin/bash

# ============================================================================
# Name:        sh_camera_run_gimbal_camera.sh
# Synopsis:    sh_camera_run_gimbal_camera.sh [rtsp_url]
#
# Description:
#   Streams frames from a gimbal RTSP source and forwards them via FFmpeg to
#   the v4l2loopback virtual camera labeled "DE-GIMBAL".
#
# Arguments:
#   rtsp_url (optional)
#       RTSP stream URL. If omitted, DEFAULT_RTSP_URL is used.
#
# Exit Codes:
#   1  Usage error or virtual camera not found.
# ============================================================================

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

# --- Configuration ---
# DEFINE YOUR INPUT OUTPUT HERE 
CAM_LABEL_PREFIX="DE-GIMBAL"
DEFAULT_RTSP_URL="rtsp://192.168.2.119:554/live/viewpro"

# --- Script Logic ---
if [ "$#" -gt 1 ]; then
    log_warn "Usage: $0 [rtsp_url]"
    log_warn "Example: $0"
    log_warn "Example: $0 rtsp://192.168.2.119:554/live/viewpro"
    exit 1
fi

RTSP_URL="${1:-$DEFAULT_RTSP_URL}"
TARGET_CAM_NAME="${CAM_LABEL_PREFIX}"
TARGET_DEVICE=""

log_info "Searching for virtual camera: ${TARGET_CAM_NAME}"

for video_dir in /sys/devices/virtual/video4linux/video*; do
    if [ -d "$video_dir" ]; then
        current_card_label=""
        if [ -f "$video_dir/name" ]; then
            current_card_label=$(cat "$video_dir/name")
        elif [ -f "$video_dir/card" ]; then
            current_card_label=$(cat "$video_dir/card")
        fi

        if [[ "$current_card_label" =~ ^[[:space:]]*${TARGET_CAM_NAME}[[:space:]]*$ ]]; then
            DEVICE_NUMBER=$(basename "$video_dir" | sed 's/^video//')
            TARGET_DEVICE="/dev/video${DEVICE_NUMBER}"
            break
        fi
    fi
done

if [ -z "$TARGET_DEVICE" ]; then
    log_error "Virtual camera '${TARGET_CAM_NAME}' not found."
    log_warn "Please ensure v4l2loopback is loaded with card_label containing '${TARGET_CAM_NAME}'."
    exit 1
fi

FFMPEG_LOGLEVEL="warning"
if [ "${DE_WRAPPER_VERBOSE:-0}" = "1" ]; then
    FFMPEG_LOGLEVEL="info"
fi

FFMPEG_COMMAND="ffmpeg -rtsp_transport tcp -i \"${RTSP_URL}\" \
  -f v4l2 -pix_fmt yuv420p \"${TARGET_DEVICE}\" -loglevel ${FFMPEG_LOGLEVEL}"

RESTART_DELAY="${DE_GIMBAL_RESTART_DELAY:-0.25}"

log_info "Found ${TARGET_CAM_NAME} at ${TARGET_DEVICE}"
log_info "Using RTSP source: ${RTSP_URL}"
log_info "Executing command: ${FFMPEG_COMMAND}"

while true; do
    # shellcheck disable=SC2086
    if eval ${FFMPEG_COMMAND}; then
        log_warn "FFmpeg exited normally. Restarting DE-GIMBAL pipeline in 1s."
    else
        exit_code=$?
        log_error "FFmpeg exited with code ${exit_code}. Restarting DE-GIMBAL pipeline in 1s."
    fi

    sleep "${RESTART_DELAY}"
done
