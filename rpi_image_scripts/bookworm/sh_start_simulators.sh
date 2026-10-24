#!/bin/bash
# sh_start_simulators.sh [1|2]
# Start ArduPilot SITL + de_comm + de_mavlink simulator instance(s) on
# droneengage.local.
#
#   no arg / 1  -> start instance 1 only  (SITL -I200, TCP 7760)
#   2           -> start instances 1 AND 2 (SITL -I200/201, TCP 7760/7770)
#
# SITL is run directly (no vehicle.py / sim_vehicle.py wrapper) and exposes
# MAVLink over TCP using the -I instance scheme:
#   instance 200 -> TCP 5760 + 10*200 = 7760
#   instance 201 -> TCP 5760 + 10*201 = 7770
# de_mavlink connects to these TCP ports as a client (fcb_connection_uri.type=tcp).
# Sim ports are intentionally different from the production de_mavlink FCB
# port (7660) so the simulator never hijacks the real unit's FC link.
# NOTE: the -I instance arg is a uint8 in SITL (wraps mod 256); -I290 would
# bind 6100, so sims use -I200/-I201.
#
# Start order per instance: SITL first (wait for TCP listen), then de_comm,
# then de_mavlink, then wait for "Mavlink Connected".
# Instances are started one at a time to avoid two SITLs doing heavy EKF
# init simultaneously (flaky early-exit on a Pi 4 during "Smoothing reset").
#
# Stop everything with sh_stop_simulators.sh.

set -u

# --- run as pi even when invoked as root (e.g. cockpit privileged bridge) ---
# All simulator paths are under /home/pi; when cockpit spawns this script via
# its privileged (root) bridge, $HOME is /root and the SITL binary / logs are
# not found. Force HOME to the pi user's home so path resolution is correct.
if [ "$(id -u)" = "0" ]; then
    export HOME=/home/pi
fi

# --- systemd-run prefix: transient units survive cockpit's cgroup cleanup ---
# When cockpit.spawn completes it tears down the spawn's cgroup, killing any
# child processes even if detached with setsid.  Starting each process as its
# own transient systemd unit puts it in a separate cgroup that is not affected.
if [ "$(id -u)" = "0" ]; then
    SD_RUN=(systemd-run)          # system manager
    SD_CTL=(systemctl)
else
    SD_RUN=(systemd-run --user)   # user manager
    SD_CTL=(systemctl --user)
fi

# --- arg: how many instances to start (default 1) ---
COUNT="${1:-1}"
if [ "$COUNT" != "1" ] && [ "$COUNT" != "2" ]; then
    echo "Usage: $0 [1|2]   (1 = sim1 only, 2 = sim1 + sim2)" >&2
    exit 1
fi

# --- paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="$HOME/simulator/sim_de_mavlink_instances"
DE_COMM_BIN="$HOME/drone_engage/de_comm/de_comm"
DE_MAVLINK_BIN="$HOME/drone_engage/de_mavlink/de_ardupilot"
SITL_BIN="$HOME/simulator/ardupilot/build/sitl/bin/arducopter"
SITL_DEFAULTS="$HOME/simulator/ardupilot/Tools/autotest/default_params/copter.parm"
LOG_DIR="$HOME/logs"

# --- colors ---
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log() { echo -e "${1}${2}${NC}"; }

# --- instance table: <inst> <sysid> <tcp_port> <s2s_listen> <s2s_target> ---
# Row 1 = instance 1, Row 2 = instance 2.
ALL_INSTANCES=( "200 1 7760 51003 51000" "201 2 7770 52003 52000" )
INSTANCES=()
for ((i=0; i<COUNT; i++)); do INSTANCES+=("${ALL_INSTANCES[i]}"); done

mkdir -p "$LOG_DIR"

# 1. Stop any previous run (always stops ALL instances).
log "${BLUE}" "Stopping any existing simulator processes..."
bash "$SCRIPT_DIR/sh_stop_simulators.sh" >/dev/null 2>&1 || true

# 2. Clean old logs (best-effort, no sudo). Do NOT delete ~/terrain — SITL
#    may need terrain data and deleting it can cause instability.
log "${BLUE}" "Cleaning old logs..."
rm -rf "$LOG_DIR"/* 2>/dev/null || true

# 3. Helpers.
wait_for_tcp_port() {
    local port=$1 timeout=${2:-40}
    for ((i=1; i<=timeout; i++)); do
        if ss -tln 2>/dev/null | grep -q ":${port} "; then
            log "${GREEN}" "TCP port ${port} is listening (after ${i}s)"
            return 0
        fi
        sleep 1
    done
    log "${RED}" "ERROR: TCP port ${port} not listening after ${timeout}s"
    return 1
}

# NOTE: SITL/de_comm/de_mavlink are launched INLINE in the loop below as
# transient systemd units (systemd-run).  This keeps each process in its own
# cgroup so it survives cockpit's cgroup teardown when cockpit.spawn completes.
# The previous setsid-based approach was killed by cockpit's cleanup.

# 4. Start instances ONE AT A TIME: SITL -> wait for port -> de_comm ->
#    de_mavlink -> wait for "Mavlink Connected" -> next instance.
#    Staggering avoids two SITLs doing heavy EKF init simultaneously, which
#    on a Pi 4 causes a flaky early-exit during "Smoothing reset".
SITL_PIDS=()
DE_COMM_PIDS=()
DE_MAVLINK_PIDS=()
n=0
for row in "${INSTANCES[@]}"; do
    n=$((n+1))
    read -r inst sysid port s2sl s2st <<< "$row"

    # --- start SITL -I${inst} ---
    inst_dir="$HOME/simulator/instances/I${inst}"
    mkdir -p "$inst_dir"
    log "${BLUE}" "Starting SITL instance -I${inst} (sysid ${sysid}, TCP ${port})..."
    sitl_log="$LOG_DIR/sitl.I${inst}.log"
    sitl_unit="de-sitl-I${inst}"
    # systemd-run creates a transient unit in its own cgroup; the bash wrapper
    # keeps stdin open (tail -f /dev/null) so SITL doesn't see EOF and exit,
    # and writes a final "SITL EXITED" line to the log after SITL terminates.
    "${SD_RUN[@]}" --unit="$sitl_unit" --collect \
        --property=WorkingDirectory="$inst_dir" \
        bash -c 'LOG="$1"; shift; "$0" "$@" < <(tail -f /dev/null) > "$LOG" 2>&1; st=$?; echo "SITL EXITED status=$st" >> "$LOG"' \
        "$SITL_BIN" "$sitl_log" --wipe --model + --speedup 1 --sysid "$sysid" --slave 0 \
        --defaults "$SITL_DEFAULTS" --sim-address 127.0.0.1 -I"$inst"
    sleep 0.5
    spid=$("${SD_CTL[@]}" show --property=MainPID --value "$sitl_unit" 2>/dev/null || echo "")
    SITL_PIDS+=("$spid")
    log "${GREEN}" "SITL -I${inst} started (PID ${spid}, unit ${sitl_unit}); cwd: ${inst_dir}; log: $LOG_DIR/sitl.I${inst}.log"

    wait_for_tcp_port "$port" 45 || { log "${RED}" "Aborting: SITL -I${inst} did not open TCP ${port}"; exit 1; }

    # --- start de_comm ---
    log "${BLUE}" "Starting de_comm instance ${n}..."
    comm_unit="de-sim-comm-${n}"
    comm_log="$LOG_DIR/de_comm.${n}.log"
    "${SD_RUN[@]}" --unit="$comm_unit" --collect \
        bash -c 'LOG="$1"; shift; exec "$0" "$@" > "$LOG" 2>&1' \
        "$DE_COMM_BIN" "$comm_log" \
        --config "$SIM_DIR/de_comm.${n}.config.module.json" \
        --bconfig "$SIM_DIR/de_comm.${n}.local"
    sleep 0.5
    cpid=$("${SD_CTL[@]}" show --property=MainPID --value "$comm_unit" 2>/dev/null || echo "")
    DE_COMM_PIDS+=("$cpid")
    log "${GREEN}" "de_comm ${n} started (PID ${cpid}, unit ${comm_unit}); log: $comm_log"
    sleep 1   # let de_comm generate/announce its party_id

    # --- start de_mavlink ---
    log "${BLUE}" "Starting de_mavlink instance ${n}..."
    mav_unit="de-sim-mavlink-${n}"
    mav_log="$LOG_DIR/de_mavlink.${n}.log"
    "${SD_RUN[@]}" --unit="$mav_unit" --collect \
        bash -c 'LOG="$1"; shift; exec "$0" "$@" > "$LOG" 2>&1' \
        "$DE_MAVLINK_BIN" "$mav_log" \
        --config "$SIM_DIR/de_mavlink.${n}.config.module.json" \
        --bconfig "$SIM_DIR/de_mavlink.${n}.local"
    sleep 0.5
    mpid=$("${SD_CTL[@]}" show --property=MainPID --value "$mav_unit" 2>/dev/null || echo "")
    DE_MAVLINK_PIDS+=("$mpid")
    log "${GREEN}" "de_mavlink ${n} started (PID ${mpid}, unit ${mav_unit}); log: $mav_log"

    # Wait for de_mavlink to confirm "Mavlink Connected" (up to 30s), then
    # give SITL a few extra seconds to finish EKF init before the next
    # instance starts heavy init.
    log "${BLUE}" "Waiting for de_mavlink ${n} to connect to SITL -I${inst}..."
    ok=""
    for ((i=1; i<=30; i++)); do
        if grep -q "Mavlink Connected" "$LOG_DIR/de_mavlink.${n}.log" 2>/dev/null; then
            ok=1; break
        fi
        if ! kill -0 "$spid" 2>/dev/null; then
            log "${RED}" "ERROR: SITL -I${inst} (PID ${spid}) died during init!"; break
        fi
        sleep 1
    done
    if [ -z "$ok" ]; then
        log "${YELLOW}" "WARNING: de_mavlink ${n} did not confirm connect within 30s; continuing anyway"
    else
        log "${GREEN}" "de_mavlink ${n} connected; letting SITL -I${inst} settle for 5s..."
        sleep 5
    fi
done

# 5. Summary.
log "${YELLOW}" "All requested processes are running (instance count: ${COUNT})."
log "${GREEN}" "SITL PIDs:     ${SITL_PIDS[*]}"
log "${GREEN}" "de_comm PIDs:  ${DE_COMM_PIDS[*]}"
log "${GREEN}" "de_mavlink PIDs: ${DE_MAVLINK_PIDS[*]}"
log "${BLUE}" "Logs in: $LOG_DIR/"
exit 0
