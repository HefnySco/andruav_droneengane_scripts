#!/bin/bash

# Script to list versions of all DroneEngage executable binaries
# Executes each binary with -v parameter and displays output

BASE_DIR="/home/pi/drone_engage"

echo "========================================"
echo "  DroneEngage Component Versions"
echo "========================================"
echo ""

if [ ! -d "$BASE_DIR" ]; then
    echo "Error: Directory $BASE_DIR does not exist"
    exit 1
fi

# Find all executable files in subdirectories
# Track seen components so each module folder is listed only once
# (e.g. de_sdr/ contains both de_sdr and de_sdr.so — only the first is shown)
declare -A seen_components
find "$BASE_DIR" -mindepth 2 -type f -executable | sort | while read -r binary; do
    # Skip common non-binary executables
    if [[ "$binary" == *.sh || "$binary" == *.py || "$binary" == *.pl ]]; then
        continue
    fi

    # Get relative path for cleaner display
    rel_path="${binary#$BASE_DIR/}"
    component_name=$(dirname "$rel_path")
    binary_name=$(basename "$binary")

    # Only show the first executable per component folder
    # (e.g. de_sdr/ has both de_sdr and de_sdr.so; de_sdr sorts first and wins.
    #  de_ai_tracker/ only has de_ai_tracker.so, so it still appears.)
    if [[ -n ${seen_components[$component_name]:-} ]]; then
        continue
    fi
    seen_components[$component_name]=1

    # Execute with -v and capture output
    version_output=$("$binary" -v 2>&1)
    exit_code=$?

    # Only display if command succeeded
    if [ $exit_code -eq 0 ]; then
        echo "----------------------------------------"
        echo "Component: $component_name"
        echo "Binary:    $binary_name"
        echo "----------------------------------------"
        echo "$version_output"
        echo ""
    fi
done

echo "========================================"
echo "  Version check complete"
echo "========================================"
