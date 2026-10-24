#!/bin/bash
# sh_stop_simulators.sh
# Stop all ArduPilot SITL + sim de_comm + sim de_mavlink processes.
# IMPORTANT: only kills SIM instances (matched by the sim config path in
# ~/simulator/sim_de_mavlink_instances/). Does NOT touch production de_comm
# or de_ardupilot running from ~/drone_engage/.
# arducopter SITL is always killed (it's only used by the simulator).

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log() { echo -e "${1}${2}${NC}"; }

# Stop transient systemd units first (created by sh_start_simulators.sh via
# systemd-run).  Try both system and user managers; ignore failures when the
# unit doesn't exist.  The pgrep-based kill below catches any leftovers.
if [ "$(id -u)" = "0" ]; then
    SD_CTL=(systemctl)
else
    SD_CTL=(systemctl --user)
fi
for unit in de-sitl-I190 de-sitl-I191 de-sitl-I200 de-sitl-I201 de-sim-comm-1 de-sim-comm-2 de-sim-mavlink-1 de-sim-mavlink-2; do
    if "${SD_CTL[@]}" is-active "$unit" >/dev/null 2>&1; then
        "${SD_CTL[@]}" stop "$unit" >/dev/null 2>&1 && log "${GREEN}" "Stopped unit ${unit}"
    fi
done
# Also try system manager in case units were created as root (e.g. by
# cockpit's privileged bridge).  Use sudo -n so it fails silently without
# a polkit/password prompt when the pi user has no cached sudo creds.
if [ "$(id -u)" != "0" ]; then
    SUDO_PREFIX=(sudo -n)
else
    SUDO_PREFIX=()
fi
for unit in de-sitl-I190 de-sitl-I191 de-sitl-I200 de-sitl-I201 de-sim-comm-1 de-sim-comm-2 de-sim-mavlink-1 de-sim-mavlink-2; do
    if "${SUDO_PREFIX[@]}" systemctl is-active "$unit" >/dev/null 2>&1; then
        "${SUDO_PREFIX[@]}" systemctl stop "$unit" >/dev/null 2>&1 && log "${GREEN}" "Stopped system unit ${unit}"
    fi
done

# Kill every process matching a pattern, retrying until none remain.
kill_process() {
    local pattern=$1 name=$2 max_attempts=5 attempt=1
    log "${BLUE}" "Terminating ${name} processes..."
    while [ $attempt -le $max_attempts ]; do
        local pids
        pids=$(pgrep -f "$pattern")
        if [ -z "$pids" ]; then
            log "${GREEN}" "No ${name} processes found"
            return 0
        fi
        for pid in $pids; do
            kill -TERM "$pid" 2>/dev/null
            log "${GREEN}" "${name} (PID ${pid}) terminated"
        done
        sleep 0.5
        if ! pgrep -f "$pattern" >/dev/null; then
            log "${GREEN}" "All ${name} processes terminated"
            return 0
        fi
        log "${YELLOW}" "Attempt ${attempt}: some ${name} still running, retrying..."
        attempt=$((attempt+1))
    done
    log "${RED}" "Failed to terminate all ${name} after ${max_attempts} attempts"
    return 1
}

# arducopter SITL is sim-only — safe to kill all.
kill_process "arducopter" "SITL arducopter"

# Only kill sim de_comm / de_mavlink (matched by binary name followed by the
# sim config path anywhere later in the command line: real command lines are
# "<binary> --config .../sim_de_mavlink_instances/...", so the binary name
# comes FIRST). This avoids killing production de_comm/de_ardupilot in
# ~/drone_engage/, which are launched with "-c <prod config>" and never
# reference sim_de_mavlink_instances.
DE_COMM_PATTERN="de_comm.*sim_de_mavlink_instances"
DE_MAVLINK_PATTERN="de_ardupilot.*sim_de_mavlink_instances"
kill_process "$DE_COMM_PATTERN"    "sim de_comm"
kill_process "$DE_MAVLINK_PATTERN" "sim de_mavlink"

log "${BLUE}" "Waiting for final termination..."
sleep 1

if pgrep -f "arducopter" >/dev/null \
   || pgrep -f "$DE_COMM_PATTERN" >/dev/null \
   || pgrep -f "$DE_MAVLINK_PATTERN" >/dev/null; then
    log "${RED}" "Some sim processes may still be running. Check manually."
    exit 1
fi
log "${GREEN}" "All sim processes successfully terminated"
exit 0
