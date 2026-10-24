#!/bin/bash

# ============================================================================
# Name:        sh_camera_run_test_stream.sh
# Synopsis:    sh_camera_run_test_stream.sh
#
# Description:
#   Generates an FFmpeg test pattern (testsrc2, 640x480 @ 120fps) and forwards
#   it as raw video to the v4l2loopback virtual camera labeled "test_stream".
#
# Arguments:
#   None.
#
# Exit Codes:
#   1  Virtual camera not found.
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
CAM_LABEL_PREFIX="test_stream"

# --- Script Logic ---
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

VIDEO_WIDTH="${DE_VIDEO_WIDTH:-640}"
VIDEO_HEIGHT="${DE_VIDEO_HEIGHT:-480}"
VIDEO_FRAMERATE="${DE_VIDEO_FRAMERATE:-120}"

FFMPEG_COMMAND="ffmpeg -hide_banner -loglevel ${FFMPEG_LOGLEVEL} \
  -f lavfi -i testsrc2=size=${VIDEO_WIDTH}x${VIDEO_HEIGHT}:rate=${VIDEO_FRAMERATE} \
  -pix_fmt yuyv422 -c:v rawvideo -f v4l2 \"${TARGET_DEVICE}\""

RESTART_DELAY="${DE_TEST_STREAM_RESTART_DELAY:-0.25}"

log_info "Found ${TARGET_CAM_NAME} at ${TARGET_DEVICE}"
log_info "Executing command: ${FFMPEG_COMMAND}"

while true; do
    # shellcheck disable=SC2086
    if eval ${FFMPEG_COMMAND}; then
        log_warn "FFmpeg exited normally. Restarting test_stream pipeline in 1s."
    else
        exit_code=$?
        log_error "FFmpeg exited with code ${exit_code}. Restarting test_stream pipeline in 1s."
    fi

    sleep "${RESTART_DELAY}"
done
