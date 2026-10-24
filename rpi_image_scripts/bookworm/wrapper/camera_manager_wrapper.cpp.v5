//***************************************************************************** */
//  Wrapper to run Camera & Related Software with optional modules and camera pipeline
//
//  Auth: Mohammad S. Hefny
//  Date: Aug 2025
//
//***************************************************************************** */

// g++ camera_manager_wrapper.cpp -o camera_manager_wrapper -pthread
#include <iostream>    // For standard input/output operations
#include <string>      // For std::string
#include <vector>      // For std::vector to handle multiple scripts
#include <cstdlib>     // For system(), exit()
#include <cstdio>      // For popen(), fgets()
#include <fstream>     // For config file reading
#include <sstream>     // For std::ostringstream
#include <thread>      // For std::this_thread::sleep_for
#include <chrono>      // For std::chrono::seconds
#include <algorithm>   // For std::find
#include <sys/types.h> // For pid_t
#include <sys/wait.h>  // For waitpid()
#include <sys/stat.h>  // For stat()
#include <unistd.h>    // For fork(), execlp(), kill(), chdir(), access(), setpgid(), readlink()
#include <dirent.h>    // For opendir(), readdir()
#include <csignal>     // For SIGTERM, SIGINT
#include <getopt.h>    // For parsing command-line options

#define VERSION_APP "5.0.0"

// Readiness and restart policy
#define READINESS_TIMEOUT_SEC 30    // wait for an upstream device to get a producer
#define MODULE_ALIVE_SEC 5          // a module is "alive" once it survives this long
#define RESTART_BACKOFF_BASE_SEC 2  // first restart delay
#define RESTART_BACKOFF_MAX_SEC 30  // backoff cap
#define MAX_CHILD_RESTARTS 5        // stack exits after one child fails this many times
#define RESTART_STABLE_SEC 300      // a child that survives this long is healthy: its restart budget resets
#define SUPERVISOR_POLL_MS 250      // monitor loop tick

// rpicam-vid | ffmpeg producer defaults (mirror sh_camera_run_rpi_camera.sh)
#define RPICAM_VID_PATH "/home/pi/rpicam-apps/build/apps/rpicam-vid"
#define RPICAM_HELLO_PATH "/home/pi/rpicam-apps/build/apps/rpicam-hello"
#define VIDEO_WIDTH 1920
#define VIDEO_HEIGHT 1080
#define VIDEO_FRAMERATE 15
#define RPI_CAMERA_OUTPUT_LABEL "DE-RPI" // clean feed consumed by de_camera

// Default base directories for drone_engage modules
const std::string DEFAULT_BASE_DRONE_ENGAGE_PATH = "/home/pi/drone_engage/";
const std::string DEFAULT_SCRIPTS_PATH = "/home/pi/scripts";

// Runtime base directories (can be overridden by command line arguments)
std::string BASE_DRONE_ENGAGE_PATH = DEFAULT_BASE_DRONE_ENGAGE_PATH;
std::string SCRIPTS_PATH = DEFAULT_SCRIPTS_PATH;

// Derived module paths (computed from BASE_DRONE_ENGAGE_PATH)
std::string BASE_CAMERA_MODULE_PATH = BASE_DRONE_ENGAGE_PATH + "de_camera/";
std::string BASE_TRACKER_MODULE_PATH = BASE_DRONE_ENGAGE_PATH + "de_tracking/";

// Perceive module dir: de_perceive preferred, de_yolo_generic kept for older deploys
std::string BASE_PERCEIVE_MODULE_PATH;

volatile sig_atomic_t g_shutdown_requested = 0;
int g_max_child_restarts = MAX_CHILD_RESTARTS; // overridable via --max-restarts

enum class ChildKind
{
    PIPELINE, // shell pipeline (rpicam-vid | ffmpeg, gimbal, test stream)
    MODULE,   // droneengage module binary (de_camera, de_tracker, de_perceive)
    SCRIPT    // custom -e script
};

/**
 * @brief A supervised child process. Pipeline/script children run through
 * `sh -c <command>` as a process-group leader; module children exec the
 * binary directly (also as group leader so kill(-pid) takes the tree down).
 */
struct ManagedChild
{
    std::string name;
    ChildKind kind;
    pid_t pid = -1;
    int restart_count = 0;
    std::chrono::steady_clock::time_point started_at; // last spawn time — a long-lived child resets its restart budget
    bool pending_restart = false;
    bool finished = false; // completed (script exit 0) or permanently failed
    std::chrono::steady_clock::time_point restart_at;
    // shell form (PIPELINE, SCRIPT)
    std::string command;
    // exec form (MODULE)
    std::string module_path;
    std::string config_path;
    std::string working_dir;
};

std::vector<ManagedChild> managed_children;

/**
 * @brief Executes a shell command and checks its exit code.
 * @param cmd The command string to execute.
 * @return True if the command executed successfully (exit code 0), false otherwise.
 */
bool executeCommand(const std::string &cmd)
{
    std::cout << "Executing: " << cmd << std::endl;
    int result = std::system(cmd.c_str());
    if (result != 0)
    {
        std::cerr << "Command failed with exit code " << result << ": " << cmd << std::endl;
        return false;
    }
    std::cout << "Command completed successfully" << std::endl;
    return true;
}

/**
 * @brief Removes C-style comments (line and block) from a JSON-with-comments document.
 * String literals are honored so URLs like "http://..." survive.
 */
std::string stripJsonComments(const std::string &text)
{
    std::string out;
    out.reserve(text.size());
    bool in_string = false;
    bool in_line_comment = false;
    bool in_block_comment = false;
    for (size_t i = 0; i < text.size(); ++i)
    {
        const char c = text[i];
        const char next = (i + 1 < text.size()) ? text[i + 1] : '\0';
        if (in_line_comment)
        {
            if (c == '\n')
            {
                in_line_comment = false;
                out += c;
            }
            continue;
        }
        if (in_block_comment)
        {
            if (c == '*' && next == '/')
            {
                in_block_comment = false;
                ++i;
            }
            continue;
        }
        if (in_string)
        {
            out += c;
            if (c == '\\' && next != '\0')
            {
                out += next;
                ++i;
            }
            else if (c == '"')
            {
                in_string = false;
            }
            continue;
        }
        if (c == '"')
        {
            in_string = true;
            out += c;
        }
        else if (c == '/' && next == '/')
        {
            in_line_comment = true;
            ++i;
        }
        else if (c == '/' && next == '*')
        {
            in_block_comment = true;
            ++i;
        }
        else
        {
            out += c;
        }
    }
    return out;
}

/**
 * @brief Finds the first "key" : "value" string pair in (comment-stripped) JSON text.
 * @return True and the value when found.
 */
bool findJsonStringValue(const std::string &json_text, const std::string &key, std::string &value_out)
{
    const std::string quoted_key = "\"" + key + "\"";
    size_t pos = json_text.find(quoted_key);
    if (pos == std::string::npos) return false;
    pos += quoted_key.size();
    pos = json_text.find(':', pos);
    if (pos == std::string::npos) return false;
    pos = json_text.find('"', pos + 1);
    if (pos == std::string::npos) return false;
    const size_t end = json_text.find('"', pos + 1);
    if (end == std::string::npos) return false;
    value_out = json_text.substr(pos + 1, end - pos - 1);
    return true;
}

/**
 * @brief Finds the first "key" : <number> pair in (comment-stripped) JSON text.
 */
bool findJsonNumberValue(const std::string &json_text, const std::string &key, long &value_out)
{
    const std::string quoted_key = "\"" + key + "\"";
    size_t pos = json_text.find(quoted_key);
    if (pos == std::string::npos) return false;
    pos += quoted_key.size();
    pos = json_text.find(':', pos);
    if (pos == std::string::npos) return false;
    ++pos;
    while (pos < json_text.size() && (json_text[pos] == ' ' || json_text[pos] == '\t')) ++pos;
    size_t end = pos;
    if (end < json_text.size() && (json_text[end] == '-' || json_text[end] == '+')) ++end;
    while (end < json_text.size() && isdigit(json_text[end])) ++end;
    if (end == pos) return false;
    value_out = std::atol(json_text.substr(pos, end - pos).c_str());
    return true;
}

/**
 * @brief Extracts the [ ... ] block following "key" (used for camera_list).
 */
bool findJsonArrayBlock(const std::string &json_text, const std::string &key, std::string &block_out)
{
    const std::string quoted_key = "\"" + key + "\"";
    size_t pos = json_text.find(quoted_key);
    if (pos == std::string::npos) return false;
    pos = json_text.find('[', pos + quoted_key.size());
    if (pos == std::string::npos) return false;
    int depth = 0;
    for (size_t i = pos; i < json_text.size(); ++i)
    {
        if (json_text[i] == '[') ++depth;
        else if (json_text[i] == ']')
        {
            if (--depth == 0)
            {
                block_out = json_text.substr(pos, i - pos + 1);
                return true;
            }
        }
    }
    return false;
}

/**
 * @brief Resolves a v4l2 card label (e.g. "DE-RPI") to a device index.
 * Scans virtual (v4l2loopback) devices first, then /sys/class/video4linux
 * so physical camera names resolve too.
 * @return device index (the N in /dev/videoN) or -1 when not found.
 */
int findVideoDeviceIndexByName(const std::string &device_name)
{
    const char *roots[] = {"/sys/devices/virtual/video4linux", "/sys/class/video4linux"};
    for (const char *root : roots)
    {
        DIR *dir = opendir(root);
        if (dir == nullptr) continue;
        struct dirent *entry;
        while ((entry = readdir(dir)) != nullptr)
        {
            const std::string dirname = entry->d_name;
            if (dirname.compare(0, 5, "video") != 0) continue;
            for (const char *attr : {"name", "card"})
            {
                std::ifstream f(std::string(root) + "/" + dirname + "/" + attr);
                std::string label;
                if (f.good() && std::getline(f, label))
                {
                    const size_t first = label.find_first_not_of(" \t\r\n");
                    const size_t last = label.find_last_not_of(" \t\r\n");
                    label = (first == std::string::npos) ? "" : label.substr(first, last - first + 1);
                    if (label == device_name)
                    {
                        closedir(dir);
                        return std::atoi(dirname.c_str() + 5);
                    }
                }
            }
        }
        closedir(dir);
    }
    return -1;
}

/**
 * @brief Resolves a configured device reference to a /dev path.
 * Accepts a card label, a "/dev/videoN" path, or a bare index "N".
 */
bool resolveDeviceRef(const std::string &device_ref, std::string &device_path_out)
{
    if (device_ref.empty()) return false;
    if (device_ref[0] == '/')
    {
        device_path_out = device_ref;
        return access(device_path_out.c_str(), F_OK) == 0;
    }
    bool numeric = !device_ref.empty() &&
                   device_ref.find_first_not_of("0123456789") == std::string::npos;
    if (numeric)
    {
        device_path_out = "/dev/video" + device_ref;
        return access(device_path_out.c_str(), F_OK) == 0;
    }
    const int index = findVideoDeviceIndexByName(device_ref);
    if (index < 0) return false;
    device_path_out = "/dev/video" + std::to_string(index);
    return access(device_path_out.c_str(), F_OK) == 0;
}

/**
 * @brief Checks whether any process currently holds the given device node open.
 * Scans /proc/<pid>/fd symlinks; no external tools needed.
 */
bool deviceHasOpener(const std::string &device_path)
{
    DIR *proc = opendir("/proc");
    if (proc == nullptr) return false;
    struct dirent *pid_entry;
    char link_target[256];
    while ((pid_entry = readdir(proc)) != nullptr)
    {
        const char *pid_name = pid_entry->d_name;
        if (!isdigit(pid_name[0])) continue;
        const std::string fd_dir = std::string("/proc/") + pid_name + "/fd";
        DIR *fds = opendir(fd_dir.c_str());
        if (fds == nullptr) continue;
        struct dirent *fd_entry;
        bool found = false;
        while ((fd_entry = readdir(fds)) != nullptr)
        {
            if (fd_entry->d_name[0] == '.') continue;
            const std::string fd_path = fd_dir + "/" + fd_entry->d_name;
            const ssize_t len = readlink(fd_path.c_str(), link_target, sizeof(link_target) - 1);
            if (len > 0)
            {
                link_target[len] = '\0';
                if (device_path == link_target)
                {
                    found = true;
                    break;
                }
            }
        }
        closedir(fds);
        if (found)
        {
            closedir(proc);
            return true;
        }
    }
    closedir(proc);
    return false;
}

/**
 * @brief Readiness gate: waits until the device has at least one opener
 * (the producer attached and frames are flowing). When the device is fed
 * by our own producer this is called while no consumers run yet, so an
 * opener means the producer.
 * @return True when producing, false on timeout.
 */
bool waitDeviceProducing(const std::string &device_path, int timeout_sec)
{
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_sec);
    while (std::chrono::steady_clock::now() < deadline && !g_shutdown_requested)
    {
        if (deviceHasOpener(device_path)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(SUPERVISOR_POLL_MS));
    }
    return false;
}

void stopAllChildren();

/**
 * @brief Forks a child for a managed entry. Pipeline/script entries run
 * `sh -c <command>`; module entries exec `<module_path> -c <config>` after
 * chdir into working_dir. Every child becomes a process-group leader so
 * kill(-pid) shuts down the whole subtree.
 * @return Child PID, -1 on fork failure, 0 when a pre-check failed.
 */
pid_t spawnChild(ManagedChild &child)
{
    if (child.kind == ChildKind::MODULE)
    {
        std::cout << "Starting module: " << child.name << std::endl;
        std::cout << "  Module path: " << child.module_path << std::endl;
        std::cout << "  Config path: " << child.config_path << std::endl;
        std::cout << "  Working dir: " << child.working_dir << std::endl;

        if (access(child.module_path.c_str(), F_OK) != 0)
        {
            std::cerr << "ERROR: Module executable not found: " << child.module_path << std::endl;
            return -1;
        }
        if (access(child.config_path.c_str(), F_OK) != 0)
        {
            std::cerr << "WARNING: Config file not found: " << child.config_path << std::endl;
        }
        if (access(child.working_dir.c_str(), F_OK) != 0)
        {
            std::cerr << "ERROR: Working directory not found: " << child.working_dir << std::endl;
            return -1;
        }
    }

    pid_t pid = fork();
    if (pid == -1)
    {
        std::cerr << "Failed to fork for " << child.name << "." << std::endl;
        return -1;
    }
    else if (pid == 0)
    {
        setpgid(0, 0);
        if (child.kind == ChildKind::MODULE)
        {
            if (chdir(child.working_dir.c_str()) == -1)
            {
                perror(("chdir for " + child.name + " failed").c_str());
                _exit(1);
            }
            std::cout << "Executing: " << child.module_path << " -c " << child.config_path
                      << " in dir " << child.working_dir << std::endl;
            execlp(child.module_path.c_str(), child.name.c_str(), "-c", child.config_path.c_str(), (char *)NULL);
            perror(("execlp for " + child.name + " failed").c_str());
            _exit(127);
        }
        else
        {
            std::cout << "Executing command: " << child.command << std::endl;
            execlp("sh", "sh", "-c", child.command.c_str(), (char *)NULL);
            perror(("execlp for " + child.name + " failed").c_str());
            _exit(127);
        }
    }

    std::cout << child.name << " started with PID: " << pid << std::endl;
    child.pid = pid;
    child.started_at = std::chrono::steady_clock::now();
    child.pending_restart = false;
    return pid;
}

/**
 * @brief Schedules a crashed child for an exponential-backoff restart.
 * @return False when the child exceeded MAX_CHILD_RESTARTS (caller tears
 * the stack down).
 */
bool scheduleRestart(ManagedChild &child, const std::string &exit_reason)
{
    ++child.restart_count;
    if (child.restart_count > g_max_child_restarts)
    {
        std::cerr << "Child '" << child.name << "' " << exit_reason << " and exceeded "
                  << g_max_child_restarts << " restarts. Crashing wrapper to force a full systemctl restart."
                  << std::endl;
        return false;
    }
    int backoff = RESTART_BACKOFF_BASE_SEC;
    for (int i = 1; i < child.restart_count && backoff < RESTART_BACKOFF_MAX_SEC; ++i)
    {
        backoff *= 2;
    }
    if (backoff > RESTART_BACKOFF_MAX_SEC) backoff = RESTART_BACKOFF_MAX_SEC;
    child.pending_restart = true;
    child.restart_at = std::chrono::steady_clock::now() + std::chrono::seconds(backoff);
    std::cerr << "Child '" << child.name << "' " << exit_reason
              << ". Restarting in " << backoff << "s (attempt " << child.restart_count
              << "/" << g_max_child_restarts << ")." << std::endl;
    return true;
}

/**
 * @brief Handles a reaped child: scripts that exit 0 are done; anything
 * else is a crash and is restarted alone with backoff.
 * @return False when the stack must exit.
 */
bool handleChildExit(pid_t exited_pid, int status)
{
    ManagedChild *child = nullptr;
    for (auto &c : managed_children)
    {
        if (c.pid == exited_pid)
        {
            child = &c;
            break;
        }
    }
    std::string exit_reason;
    if (WIFEXITED(status))
    {
        exit_reason = "exited with status " + std::to_string(WEXITSTATUS(status));
    }
    else if (WIFSIGNALED(status))
    {
        exit_reason = "terminated by signal " + std::to_string(WTERMSIG(status));
    }
    else
    {
        exit_reason = "exited for unknown reason";
    }

    if (child == nullptr)
    {
        std::cerr << "Child process (PID " << exited_pid << ") " << exit_reason << " (unmanaged)." << std::endl;
        return true;
    }

    child->pid = -1;

    if (child->kind == ChildKind::SCRIPT && WIFEXITED(status) && WEXITSTATUS(status) == 0)
    {
        std::cout << "Script '" << child->name << "' completed successfully." << std::endl;
        child->finished = true;
        return true;
    }

    // a dead pipeline can leave grandchildren (rpicam-vid/ffmpeg) behind:
    // sweep the rest of its process group before restarting
    if (child->kind == ChildKind::PIPELINE)
    {
        kill(-exited_pid, SIGTERM);
    }

    std::cerr << "Child '" << child->name << "' (PID " << exited_pid << ") " << exit_reason << "." << std::endl;

    // crash-loop detection: a child that stayed up past the stable window
    // is not looping — scattered crashes must not exhaust the budget
    const auto uptime = std::chrono::steady_clock::now() - child->started_at;
    if (child->restart_count > 0 && uptime >= std::chrono::seconds(RESTART_STABLE_SEC))
    {
        std::cout << "Child '" << child->name << "' ran "
                  << std::chrono::duration_cast<std::chrono::seconds>(uptime).count()
                  << "s before this crash - resetting restart budget." << std::endl;
        child->restart_count = 0;
    }
    return scheduleRestart(*child, exit_reason);
}

/**
 * @brief Startup alive-check: the child "reports alive" by surviving the
 * window without exiting. If it dies inside the window it is handed to
 * the normal restart path.
 * @return True when still running after alive_seconds.
 */
bool waitModuleAlive(ManagedChild &child, int alive_seconds)
{
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(alive_seconds);
    while (std::chrono::steady_clock::now() < deadline && !g_shutdown_requested)
    {
        if (child.pending_restart)
        {
            return true; // died early, restart already scheduled
        }
        if (child.pid > 0)
        {
            int status;
            const pid_t result = waitpid(child.pid, &status, WNOHANG);
            if (result == child.pid)
            {
                if (!handleChildExit(child.pid, status))
                {
                    return false; // exceeded max restarts during startup
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(SUPERVISOR_POLL_MS));
    }
    return true;
}

/**
 * @brief Gracefully stops all running child process groups.
 */
void stopAllChildren()
{
    for (auto &child : managed_children)
    {
        if (child.pid > 0)
        {
            std::cout << "Stopping " << child.name << " (PID " << child.pid << ")..." << std::endl;
            kill(-child.pid, SIGTERM); // process group: pipelines take ffmpeg/rpicam down too
            kill(child.pid, SIGTERM);  // plain pid too, in case setpgid had not run yet
        }
    }

    // reap exited children; SIGKILL whatever is still alive after the grace window
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(4);
    bool any_alive = true;
    while (any_alive && std::chrono::steady_clock::now() < deadline)
    {
        int status;
        while (waitpid(-1, &status, WNOHANG) > 0) {}
        any_alive = false;
        for (auto &child : managed_children)
        {
            if (child.pid > 0 && kill(child.pid, 0) == 0) any_alive = true;
        }
        if (any_alive) std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    for (auto &child : managed_children)
    {
        if (child.pid > 0 && kill(child.pid, 0) == 0)
        {
            kill(-child.pid, SIGKILL);
            kill(child.pid, SIGKILL);
        }
    }
    int status;
    while (waitpid(-1, &status, WNOHANG) > 0) {}
}

/**
 * @brief Pre-emptively kills any running instances of child processes.
 */
void preemptiveKill()
{
    std::cout << "Pre-emptively killing any old camera processes..." << std::endl;
    // our own children first, via their process groups
    stopAllChildren();
    std::string kill_script = SCRIPTS_PATH;
    if (kill_script.back() == '/') kill_script.pop_back();  // Remove trailing slash
    executeCommand("sudo " + kill_script + "/sh_kill_all_camera_apps.sh");
    // v5 module names are not in the legacy kill script
    executeCommand("sudo pkill --signal 9 -f 'de_perceive|de_yolo_generic_rknn' 2>/dev/null");
    std::this_thread::sleep_for(std::chrono::seconds(2));
}

/**
 * @brief Signal handler for termination signals (SIGINT, SIGTERM).
 */
void signal_handler(int signal_num)
{
    (void)signal_num;
    g_shutdown_requested = 1;
}

/**
 * @brief Reads a whole text file.
 */
bool readTextFile(const std::string &path, std::string &content_out)
{
    std::ifstream f(path);
    if (!f.good()) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    content_out = ss.str();
    return true;
}

/**
 * @brief Validates one device-naming config field of a module and resolves it.
 * device_ref may be a card label ("DE-TRK"), a "/dev/videoN" path, or an index.
 * @return True when the field is absent (nothing to validate) or resolves.
 * Fails loudly naming the module, config, field and value otherwise.
 */
bool validateDeviceField(const std::string &module_name, const std::string &config_path,
                         const std::string &json_text, const std::string &field_name,
                         std::string &resolved_path_out)
{
    std::string device_ref;
    if (!findJsonStringValue(json_text, field_name, device_ref) || device_ref.empty())
    {
        return true; // field absent: the module applies its own defaults
    }
    if (!resolveDeviceRef(device_ref, resolved_path_out))
    {
        std::cerr << "CONFIG ERROR: module '" << module_name << "' config " << config_path
                  << ": device '" << device_ref << "' (" << field_name
                  << ") does not exist - no /dev/video* device matches it." << std::endl;
        return false;
    }
    std::cout << "  " << module_name << " " << field_name << " '" << device_ref
              << "' -> " << resolved_path_out << std::endl;
    return true;
}

/**
 * @brief Validates the input/output video devices named by a module config
 * (source_video_device[_name], output_video_device[_name]).
 * @return False on the first broken reference.
 */
bool validateModuleDevices(const std::string &module_name, const std::string &config_path,
                           bool require_input, bool require_output,
                           std::string &input_device_out, std::string &output_device_out)
{
    std::string raw;
    if (!readTextFile(config_path, raw))
    {
        std::cerr << "CONFIG ERROR: module '" << module_name << "' config not readable: "
                  << config_path << std::endl;
        return false;
    }
    const std::string json_text = stripJsonComments(raw);

    if (!validateDeviceField(module_name, config_path, json_text, "source_video_device_name", input_device_out)) return false;
    if (input_device_out.empty() &&
        !validateDeviceField(module_name, config_path, json_text, "source_video_device", input_device_out)) return false;
    if (!validateDeviceField(module_name, config_path, json_text, "output_video_device_name", output_device_out)) return false;
    if (output_device_out.empty() &&
        !validateDeviceField(module_name, config_path, json_text, "output_video_device", output_device_out)) return false;

    if (require_input && input_device_out.empty())
    {
        std::cerr << "CONFIG ERROR: module '" << module_name << "' config " << config_path
                  << " names no input device (source_video_device / source_video_device_name)."
                  << std::endl;
        return false;
    }
    if (require_output && output_device_out.empty())
    {
        std::cerr << "CONFIG ERROR: module '" << module_name << "' config " << config_path
                  << " names no output device (output_video_device / output_video_device_name)."
                  << std::endl;
        return false;
    }
    if (!input_device_out.empty() && input_device_out == output_device_out)
    {
        std::cerr << "CONFIG ERROR: module '" << module_name << "' config " << config_path
                  << ": source and output are the same device " << input_device_out << std::endl;
        return false;
    }
    return true;
}

/**
 * @brief Validates the de_camera camera_list entries (device_name / device_num).
 * Scan-range configs (camera_start_index/camera_end_index) have no device
 * names to validate; a warning is printed instead.
 */
bool validateCameraModuleDevices(const std::string &module_name, const std::string &config_path)
{
    std::string raw;
    if (!readTextFile(config_path, raw))
    {
        std::cerr << "CONFIG ERROR: module '" << module_name << "' config not readable: "
                  << config_path << std::endl;
        return false;
    }
    const std::string json_text = stripJsonComments(raw);

    std::string camera_list;
    if (!findJsonArrayBlock(json_text, "camera_list", camera_list))
    {
        std::cout << "  " << module_name << " uses camera scan range (no camera_list); "
                  << "no device names to validate." << std::endl;
        return true;
    }

    bool ok = true;
    // every { ... } entry may carry "device_name" or "device_num"
    size_t pos = 0;
    int entry_index = 0;
    while ((pos = camera_list.find('{', pos)) != std::string::npos)
    {
        const size_t end = camera_list.find('}', pos);
        if (end == std::string::npos) break;
        const std::string entry = camera_list.substr(pos, end - pos + 1);
        ++entry_index;

        std::string device_name;
        if (findJsonStringValue(entry, "device_name", device_name) && !device_name.empty())
        {
            std::string resolved;
            if (!resolveDeviceRef(device_name, resolved))
            {
                std::cerr << "CONFIG ERROR: module '" << module_name << "' config " << config_path
                          << ": camera_list entry " << entry_index << " names device '" << device_name
                          << "' which does not exist." << std::endl;
                ok = false;
            }
            else
            {
                std::cout << "  " << module_name << " camera_list '" << device_name
                          << "' -> " << resolved << std::endl;
            }
        }
        long device_num = -1;
        if (findJsonNumberValue(entry, "device_num", device_num) && device_num >= 0)
        {
            const std::string path = "/dev/video" + std::to_string(device_num);
            if (access(path.c_str(), F_OK) != 0)
            {
                std::cerr << "CONFIG ERROR: module '" << module_name << "' config " << config_path
                          << ": camera_list entry " << entry_index << " uses " << path
                          << " which does not exist." << std::endl;
                ok = false;
            }
        }
        pos = end + 1;
    }
    return ok;
}

/**
 * @brief Runs rpicam-hello --list-cameras to check an RPi camera is attached.
 * @return True when a camera was detected.
 */
bool detectRpiCamera()
{
    std::string rpicam_hello = RPICAM_HELLO_PATH;
    if (access(rpicam_hello.c_str(), F_OK) != 0) rpicam_hello = "rpicam-hello";

    std::cout << "Checking for Raspberry Pi camera..." << std::endl;
    FILE *pipe = popen((rpicam_hello + " --list-cameras 2>&1").c_str(), "r");
    if (pipe == nullptr)
    {
        std::cerr << "Failed to run " << rpicam_hello << std::endl;
        return false;
    }
    std::string output;
    char buffer[256];
    while (fgets(buffer, sizeof(buffer), pipe) != nullptr)
    {
        output += buffer;
    }
    pclose(pipe);

    std::string lowered = output;
    std::transform(lowered.begin(), lowered.end(), lowered.begin(), ::tolower);
    const bool detected = lowered.find("available cameras") != std::string::npos;
    if (!detected)
    {
        std::cout << "No Raspberry Pi camera detected." << std::endl;
    }
    return detected;
}

/**
 * @brief Builds the rpicam-vid | ffmpeg fan-out command (TASK-03 topology):
 * one producer, one -f v4l2 output per consumer device.
 */
std::string buildCameraPipelineCommand(const std::vector<std::string> &output_devices,
                                       const std::string &postprocess_file)
{
    std::string rpicam_vid = RPICAM_VID_PATH;
    if (access(rpicam_vid.c_str(), F_OK) != 0) rpicam_vid = "rpicam-vid";

    std::ostringstream cmd;
    cmd << rpicam_vid << " -t 0 --nopreview --vflip=1"
        << " --width " << VIDEO_WIDTH << " --height " << VIDEO_HEIGHT
        << " --framerate " << VIDEO_FRAMERATE
        << " --codec yuv420 --info-text \"\"";
    if (!postprocess_file.empty())
    {
        cmd << " --post-process-file \"" << postprocess_file << "\"";
    }
    cmd << " -o - | ffmpeg -f rawvideo -pixel_format yuv420p"
        << " -video_size " << VIDEO_WIDTH << "x" << VIDEO_HEIGHT << " -i -";
    for (const auto &device : output_devices)
    {
        cmd << " -f v4l2 -pixel_format yuv420p " << device;
    }
    cmd << " -loglevel quiet";
    return cmd.str();
}

void printUsage(const char *argv0)
{
    std::cerr << "Usage: " << argv0 << " [--enable-rpi-cam-capture] [--enable-gimbal-capture] [--enable-test-stream] [--enable-tracker] [--perceive-backend <backend>] [--disable-de-camera] [--execute script_path] [--drone-engage-path path] [--scripts-path path] [--readiness-timeout seconds] [--module-alive seconds] [--max-restarts n] [postprocess_file_path]" << std::endl;
    std::cerr << "  -p, --perceive-backend <backend>  start de_perceive; backend: onnx|rknn|hailo|imx500_udp" << std::endl;
    std::cerr << "  -t, --enable-tracker              start de_tracker (lock-on; consumes de_perceive observations)" << std::endl;
    std::cerr << "Example: " << argv0 << " --enable-rpi-cam-capture" << std::endl;
    std::cerr << "Example: " << argv0 << " --enable-rpi-cam-capture --perceive-backend onnx --enable-tracker" << std::endl;
    std::cerr << "Example: " << argv0 << " --enable-rpi-cam-capture --perceive-backend imx500_udp \"/usr/share/rpi-camera-assets/imx500_mobilenet_ssd.json\"" << std::endl;
    std::cerr << "Example: " << argv0 << " --enable-gimbal-capture" << std::endl;
    std::cerr << "Example: " << argv0 << " --enable-test-stream" << std::endl;
    std::cerr << "Example: " << argv0 << " --enable-rpi-cam-capture --execute /path/to/script.sh" << std::endl;
    std::cerr << "Example: " << argv0 << " --drone-engage-path /custom/path/drone_engage --enable-rpi-cam-capture" << std::endl;
    std::cerr << "Example: " << argv0 << " --scripts-path /custom/scripts --enable-rpi-cam-capture" << std::endl;
}

int main(int argc, char *argv[])
{
    // Command-line options
    bool enable_rpi_cam_capture = false;
    bool enable_gimbal_capture = false;
    bool enable_test_stream = false;
    bool enable_tracker = false;
    bool enable_de_camera = true; // Enabled by default
    std::string perceive_backend; // empty = no de_perceive
    std::string postProcessFilePath;
    std::vector<std::string> scripts_to_execute; // To store script paths

    int readiness_timeout_sec = READINESS_TIMEOUT_SEC;
    int module_alive_sec = MODULE_ALIVE_SEC;

    std::cout << "Camera Wrapper ver: " << VERSION_APP << std::endl;

    // Parse command-line options
    static struct option long_options[] = {
        {"enable-rpi-cam-capture", no_argument, 0, 'c'},
        {"enable-gimbal-capture", no_argument, 0, 'm'},
        {"enable-test-stream", no_argument, 0, 's'},
        {"enable-tracker", no_argument, 0, 't'},
        {"perceive-backend", required_argument, 0, 'p'},
        {"disable-de-camera", no_argument, 0, 'd'},
        {"execute", required_argument, 0, 'e'},
        {"drone-engage-path", required_argument, 0, 'D'},
        {"scripts-path", required_argument, 0, 'S'},
        {"readiness-timeout", required_argument, 0, 'R'},
        {"module-alive", required_argument, 0, 'L'},
        {"max-restarts", required_argument, 0, 'X'},
        {"version", no_argument, 0, 'v'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}};

    int opt;
    while ((opt = getopt_long(argc, argv, "cmstp:de:D:S:R:L:X:vh", long_options, nullptr)) != -1)
    {
        switch (opt)
        {
        case 'c':
            enable_rpi_cam_capture = true;
            break;
        case 'm':
            enable_gimbal_capture = true;
            break;
        case 's':
            enable_test_stream = true;
            break;
        case 't':
            enable_tracker = true;
            break;
        case 'p':
            if (optarg && optarg[0] != '\0')
            {
                perceive_backend = optarg;
            }
            else
            {
                std::cerr << "Error: No backend provided for --perceive-backend option." << std::endl;
                return 1;
            }
            break;
        case 'd':
            enable_de_camera = false;
            break;
        case 'e':
            if (optarg && optarg[0] != '\0') // Check for non-null and non-empty
                scripts_to_execute.push_back(optarg);
            else
            {
                std::cerr << "Error: No valid script path provided for --execute option." << std::endl;
                return 1;
            }
            break;
        case 'v':
            std::cout << "Version: " << VERSION_APP << std::endl;
            return 0;
        case 'h':
            printUsage(argv[0]);
            return 0;
        case 'D':
            if (optarg && optarg[0] != '\0')
            {
                BASE_DRONE_ENGAGE_PATH = optarg;
                // Ensure path ends with exactly one /
                if (BASE_DRONE_ENGAGE_PATH.back() != '/')
                    BASE_DRONE_ENGAGE_PATH += "/";
            }
            else
            {
                std::cerr << "Error: No valid drone engage path provided for --drone-engage-path option." << std::endl;
                return 1;
            }
            break;
        case 'S':
            if (optarg && optarg[0] != '\0')
            {
                SCRIPTS_PATH = optarg;
                // Ensure path ends with exactly one /
                if (SCRIPTS_PATH.back() != '/')
                    SCRIPTS_PATH += "/";
            }
            else
            {
                std::cerr << "Error: No valid scripts path provided for --scripts-path option." << std::endl;
                return 1;
            }
            break;
        case 'R':
            if (optarg && optarg[0] != '\0')
            {
                readiness_timeout_sec = std::atoi(optarg);
                if (readiness_timeout_sec <= 0) readiness_timeout_sec = READINESS_TIMEOUT_SEC;
            }
            break;
        case 'L':
            if (optarg && optarg[0] != '\0')
            {
                module_alive_sec = std::atoi(optarg);
                if (module_alive_sec < 0) module_alive_sec = MODULE_ALIVE_SEC;
            }
            break;
        case 'X':
            if (optarg && optarg[0] != '\0')
            {
                g_max_child_restarts = std::atoi(optarg);
                if (g_max_child_restarts < 1) g_max_child_restarts = MAX_CHILD_RESTARTS;
            }
            break;
        default:
            printUsage(argv[0]);
            return 1;
        }
    }

    const bool enable_perceive = !perceive_backend.empty();
    if (enable_perceive &&
        perceive_backend != "onnx" && perceive_backend != "rknn" &&
        perceive_backend != "hailo" && perceive_backend != "imx500_udp")
    {
        std::cerr << "Error: unknown perceive backend '" << perceive_backend
                  << "' (supported: onnx|rknn|hailo|imx500_udp)" << std::endl;
        return 1;
    }

    // Parse optional postprocess_file_path (rpicam-vid --post-process-file,
    // e.g. the IMX500 JSON the imx500_udp backend relies on)
    if (optind < argc && argv[optind] != nullptr && argv[optind][0] != '\0')
    {
        postProcessFilePath = argv[optind];
        if (access(postProcessFilePath.c_str(), F_OK) != 0)
        {
            std::cerr << "Error: postprocess file not found: " << postProcessFilePath << std::endl;
            return 1;
        }
    }
    if (perceive_backend == "imx500_udp" && postProcessFilePath.empty())
    {
        std::cerr << "WARNING: imx500_udp backend without an IMX500 postprocess JSON - "
                  << "rpicam-vid will not emit on-sensor detections." << std::endl;
    }

    // Update derived module paths based on final base path (after parsing arguments)
    BASE_CAMERA_MODULE_PATH = BASE_DRONE_ENGAGE_PATH + "de_camera/";
    BASE_TRACKER_MODULE_PATH = BASE_DRONE_ENGAGE_PATH + "de_tracking/";
    // de_perceive deploy dir: prefer de_perceive, fall back to de_yolo_generic
    if (access((BASE_DRONE_ENGAGE_PATH + "de_perceive/").c_str(), F_OK) == 0)
    {
        BASE_PERCEIVE_MODULE_PATH = BASE_DRONE_ENGAGE_PATH + "de_perceive/";
    }
    else
    {
        BASE_PERCEIVE_MODULE_PATH = BASE_DRONE_ENGAGE_PATH + "de_yolo_generic/";
    }

    // Update module paths based on final base paths (after parsing arguments)
    const std::string DE_CAMERA_MODULE = BASE_CAMERA_MODULE_PATH + "de_camera";
    const std::string DE_CAMERA_CONFIG = BASE_CAMERA_MODULE_PATH +
        (enable_test_stream ? "de_camera.config.module.teststream.json" : "de_camera.config.module.json");
    const std::string TRACKING_MODULE = BASE_TRACKER_MODULE_PATH + "de_tracker";
    const std::string TRACKING_CONFIG = BASE_TRACKER_MODULE_PATH + "de_tracker.config.module.json";

    // de_perceive binary + config depend on the selected backend
    std::string PERCEIVE_MODULE;
    std::string PERCEIVE_CONFIG;
    if (enable_perceive)
    {
        // every backend runs the same de_perceive binary; -p only picks the config
        PERCEIVE_MODULE = BASE_PERCEIVE_MODULE_PATH + "de_perceive";
        if (perceive_backend == "rknn")
        {
            // the rknn variant config keeps its historical file name
            PERCEIVE_CONFIG = BASE_PERCEIVE_MODULE_PATH + "de_yolo_ai_generic_rknn.config.module.json";
        }
        else
        {
            // optional per-backend config (e.g. de_perceive.config.module.hailo.json)
            const std::string backend_config = BASE_PERCEIVE_MODULE_PATH +
                "de_perceive.config.module." + perceive_backend + ".json";
            PERCEIVE_CONFIG = (access(backend_config.c_str(), F_OK) == 0)
                ? backend_config
                : BASE_PERCEIVE_MODULE_PATH + "de_perceive.config.module.json";
        }
    }

    // Display current paths for debugging
    std::cout << "Using paths:" << std::endl;
    std::cout << "  DroneEngage: " << BASE_DRONE_ENGAGE_PATH << std::endl;
    std::cout << "  Camera: " << BASE_CAMERA_MODULE_PATH << std::endl;
    std::cout << "  Tracker: " << BASE_TRACKER_MODULE_PATH << std::endl;
    if (enable_perceive) std::cout << "  Perceive (" << perceive_backend << "): " << BASE_PERCEIVE_MODULE_PATH << std::endl;
    std::cout << "  Scripts: " << SCRIPTS_PATH << std::endl;
    std::cout << "Supervision: readiness timeout " << readiness_timeout_sec
              << "s, module alive " << module_alive_sec
              << "s, max restarts " << g_max_child_restarts << std::endl;

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    // Step 1: Pre-emptive kill of old processes
    preemptiveKill();
    if (g_shutdown_requested) return 0;

    // Step 2: Always load v4l2loopback module
    std::string create_vc_script = SCRIPTS_PATH;
    if (create_vc_script.back() == '/') create_vc_script.pop_back();  // Remove trailing slash
    if (!executeCommand(create_vc_script + "/sh_camera_create_named_vc.sh"))
    {
        std::cerr << "Failed to load v4l2loopback module. Exiting." << std::endl;
        return 1;
    }
    executeCommand("ls /sys/devices/virtual/video4linux/");

    // Step 3: Validate every enabled module's configured devices BEFORE
    // starting anything (catches stale names like SIM-CAM1 drift).
    std::cout << "Validating module device configuration..." << std::endl;
    std::string perceive_input_device;
    std::string perceive_output_device;
    std::string tracker_input_device;
    std::string tracker_output_device;
    bool config_ok = true;

    if (enable_perceive)
    {
        // imx500_udp takes detections over UDP, not a video device
        const bool perceive_uses_video = (perceive_backend != "imx500_udp");
        if (!validateModuleDevices("de_perceive", PERCEIVE_CONFIG, perceive_uses_video, perceive_uses_video,
                                   perceive_input_device, perceive_output_device))
        {
            config_ok = false;
        }
        else
        {
            // The backend name in the config must match -p when a backend key exists
            std::string raw;
            if (readTextFile(PERCEIVE_CONFIG, raw))
            {
                std::string config_backend;
                if (findJsonStringValue(stripJsonComments(raw), "backend", config_backend) &&
                    config_backend != perceive_backend)
                {
                    std::cerr << "CONFIG ERROR: de_perceive config " << PERCEIVE_CONFIG
                              << " has backend '" << config_backend << "' but -p requested '"
                              << perceive_backend << "'." << std::endl;
                    config_ok = false;
                }
            }
        }
    }
    if (enable_tracker &&
        !validateModuleDevices("de_tracker", TRACKING_CONFIG, true, false,
                               tracker_input_device, tracker_output_device))
    {
        config_ok = false;
    }
    if (enable_de_camera && !validateCameraModuleDevices("de_camera", DE_CAMERA_CONFIG))
    {
        config_ok = false;
    }
    // v4l2loopback devices are single-consumer: two enabled consumers must not
    // share one input device
    if (enable_perceive && enable_tracker && !perceive_input_device.empty() &&
        perceive_input_device == tracker_input_device)
    {
        std::cerr << "CONFIG ERROR: de_perceive and de_tracker share input device "
                  << perceive_input_device << " - give each its own device." << std::endl;
        config_ok = false;
    }
    if (!config_ok)
    {
        std::cerr << "Device validation failed. Exiting." << std::endl;
        return 1;
    }

    // Step 4: Build the producer fan-out: DE-RPI for de_camera plus one output
    // per consumer input device (de_perceive clean feed, de_tracker clean feed).
    std::vector<std::string> camera_output_devices;
    if (enable_rpi_cam_capture)
    {
        std::string primary_output;
        if (!resolveDeviceRef(RPI_CAMERA_OUTPUT_LABEL, primary_output))
        {
            std::cerr << "CONFIG ERROR: virtual camera '" << RPI_CAMERA_OUTPUT_LABEL
                      << "' not found - check sh_camera_create_named_vc.sh card_label." << std::endl;
            return 1;
        }
        camera_output_devices.push_back(primary_output);

        const std::pair<std::string, std::string> consumer_inputs[] = {
            {"de_perceive", perceive_input_device},
            {"de_tracker", tracker_input_device}};
        for (const auto &consumer : consumer_inputs)
        {
            const std::string &input_device = consumer.second;
            if (input_device.empty()) continue;
            if (std::find(camera_output_devices.begin(), camera_output_devices.end(), input_device) ==
                camera_output_devices.end())
            {
                camera_output_devices.push_back(input_device);
            }
            else if (input_device == primary_output)
            {
                // input is the de_camera feed itself
                std::cerr << "WARNING: '" << consumer.first << "' reads the de_camera feed "
                          << input_device << " - if de_camera opens it too, only one wins." << std::endl;
            }
            else
            {
                // already a producer output for another consumer: two readers on one
                // single-consumer device can never work
                std::cerr << "CONFIG ERROR: '" << consumer.first << "' input device " << input_device
                          << " is shared with another module - give each its own device." << std::endl;
                return 1;
            }
        }
        // a producer output must not double as a module output device (two writers)
        const std::pair<std::string, std::string> module_outputs[] = {
            {"de_perceive", perceive_output_device},
            {"de_tracker", tracker_output_device}};
        for (const auto &output_device : camera_output_devices)
        {
            for (const auto &module_output : module_outputs)
            {
                if (!module_output.second.empty() && output_device == module_output.second)
                {
                    std::cerr << "CONFIG ERROR: producer output " << output_device
                              << " is also the output device of " << module_output.first
                              << " - two writers on one device." << std::endl;
                    return 1;
                }
            }
        }
    }

    auto isProducerOutput = [&camera_output_devices](const std::string &device) {
        return !device.empty() &&
               std::find(camera_output_devices.begin(), camera_output_devices.end(), device) !=
                   camera_output_devices.end();
    };

    // Step 5: Register and start the producer pipelines
    if (enable_rpi_cam_capture)
    {
        if (!detectRpiCamera())
        {
            std::cout << "No Raspberry Pi camera detected, but continuing with other modules if enabled." << std::endl;
        }
        else
        {
            ManagedChild pipeline;
            pipeline.name = "camera_pipeline";
            pipeline.kind = ChildKind::PIPELINE;
            pipeline.command = buildCameraPipelineCommand(camera_output_devices, postProcessFilePath);
            if (spawnChild(pipeline) > 0)
            {
                managed_children.push_back(pipeline);
                // readiness: wait until every fan-out device has its producer
                for (const auto &device : camera_output_devices)
                {
                    if (!waitDeviceProducing(device, readiness_timeout_sec))
                    {
                        std::cerr << "WARNING: camera pipeline is not producing on " << device
                                  << " after " << readiness_timeout_sec << "s." << std::endl;
                    }
                    else
                    {
                        std::cout << "Camera pipeline producing on " << device << std::endl;
                    }
                }
            }
            else
            {
                std::cerr << "CRITICAL: Failed to start camera pipeline. Exiting." << std::endl;
                stopAllChildren();
                return 1;
            }
        }
    }
    else
    {
        std::cout << "Skipping camera pipeline (not enabled)." << std::endl;
    }

    // Step 5b: Start gimbal RTSP | ffmpeg pipeline if enabled
    if (enable_gimbal_capture)
    {
        std::string scripts_dir = SCRIPTS_PATH;
        if (scripts_dir.back() == '/') scripts_dir.pop_back();
        ManagedChild gimbal;
        gimbal.name = "gimbal_pipeline";
        gimbal.kind = ChildKind::PIPELINE;
        gimbal.command = scripts_dir + "/sh_camera_run_gimbal_camera.sh";
        if (spawnChild(gimbal) > 0)
        {
            managed_children.push_back(gimbal);
            std::string gimbal_device;
            if (resolveDeviceRef("DE-GIMBAL", gimbal_device))
            {
                if (!waitDeviceProducing(gimbal_device, readiness_timeout_sec))
                {
                    std::cerr << "WARNING: gimbal pipeline is not producing on " << gimbal_device
                              << " after " << readiness_timeout_sec << "s." << std::endl;
                }
            }
        }
        else
        {
            std::cerr << "CRITICAL: Failed to start gimbal camera pipeline. Exiting." << std::endl;
            stopAllChildren();
            return 1;
        }
    }
    else
    {
        std::cout << "Skipping gimbal camera pipeline (not enabled)." << std::endl;
    }

    // Step 5c: Start ffmpeg testsrc2 pipeline for test_stream if enabled
    if (enable_test_stream)
    {
        std::string scripts_dir = SCRIPTS_PATH;
        if (scripts_dir.back() == '/') scripts_dir.pop_back();
        ManagedChild test_stream;
        test_stream.name = "test_stream_pipeline";
        test_stream.kind = ChildKind::PIPELINE;
        test_stream.command = scripts_dir + "/sh_camera_run_test_stream.sh";
        if (spawnChild(test_stream) > 0)
        {
            managed_children.push_back(test_stream);
            std::string test_device;
            if (resolveDeviceRef("test_stream", test_device))
            {
                if (!waitDeviceProducing(test_device, readiness_timeout_sec))
                {
                    std::cerr << "WARNING: test stream pipeline is not producing on " << test_device
                              << " after " << readiness_timeout_sec << "s." << std::endl;
                }
            }
        }
        else
        {
            std::cerr << "CRITICAL: Failed to start test stream pipeline. Exiting." << std::endl;
            stopAllChildren();
            return 1;
        }
    }
    else
    {
        std::cout << "Skipping test stream pipeline (not enabled)." << std::endl;
    }

    // Step 6: Start any specified scripts
    for (const auto &script : scripts_to_execute)
    {
        std::cout << "Starting script: " << script << "..." << std::endl;
        ManagedChild script_child;
        script_child.name = "script:" + script;
        script_child.kind = ChildKind::SCRIPT;
        script_child.command = script;
        if (spawnChild(script_child) > 0)
        {
            managed_children.push_back(script_child);
        }
        else
        {
            std::cout << "Script " << script << " failed to start, but continuing with other modules if enabled." << std::endl;
        }
    }

    // Step 7: Start de_perceive once its input device is producing
    if (enable_perceive)
    {
        if (isProducerOutput(perceive_input_device) &&
            !waitDeviceProducing(perceive_input_device, readiness_timeout_sec))
        {
            std::cerr << "WARNING: " << perceive_input_device << " not producing before de_perceive start." << std::endl;
        }
        ManagedChild perceive;
        perceive.name = "de_perceive";
        perceive.kind = ChildKind::MODULE;
        perceive.module_path = PERCEIVE_MODULE;
        perceive.config_path = PERCEIVE_CONFIG;
        perceive.working_dir = BASE_PERCEIVE_MODULE_PATH;
        if (spawnChild(perceive) <= 0)
        {
            std::cerr << "CRITICAL: Failed to start de_perceive. Exiting." << std::endl;
            stopAllChildren();
            return 1;
        }
        managed_children.push_back(perceive);
        if (!waitModuleAlive(managed_children.back(), module_alive_sec))
        {
            std::cerr << "CRITICAL: de_perceive failed during startup. Exiting." << std::endl;
            stopAllChildren();
            return 1;
        }
    }
    else
    {
        std::cout << "Skipping de_perceive (no --perceive-backend)." << std::endl;
    }

    // Step 8: Start de_tracker (lock-on) once its input device is producing
    if (enable_tracker)
    {
        if (isProducerOutput(tracker_input_device) &&
            !waitDeviceProducing(tracker_input_device, readiness_timeout_sec))
        {
            std::cerr << "WARNING: " << tracker_input_device << " not producing before de_tracker start." << std::endl;
        }
        ManagedChild tracker;
        tracker.name = "de_tracker";
        tracker.kind = ChildKind::MODULE;
        tracker.module_path = TRACKING_MODULE;
        tracker.config_path = TRACKING_CONFIG;
        tracker.working_dir = BASE_TRACKER_MODULE_PATH;
        if (spawnChild(tracker) <= 0)
        {
            std::cerr << "CRITICAL: Failed to start de_tracker. Exiting." << std::endl;
            stopAllChildren();
            return 1;
        }
        managed_children.push_back(tracker);
        if (!waitModuleAlive(managed_children.back(), module_alive_sec))
        {
            std::cerr << "CRITICAL: de_tracker failed during startup. Exiting." << std::endl;
            stopAllChildren();
            return 1;
        }
    }
    else
    {
        std::cout << "Skipping de_tracker (not enabled)." << std::endl;
    }

    // Step 9: Start de_camera last, once the stream source is producing
    if (enable_de_camera)
    {
        if (enable_rpi_cam_capture && !camera_output_devices.empty() &&
            !waitDeviceProducing(camera_output_devices.front(), readiness_timeout_sec))
        {
            std::cerr << "WARNING: " << camera_output_devices.front()
                      << " not producing before de_camera start." << std::endl;
        }
        ManagedChild camera;
        camera.name = "de_camera";
        camera.kind = ChildKind::MODULE;
        camera.module_path = DE_CAMERA_MODULE;
        camera.config_path = DE_CAMERA_CONFIG;
        camera.working_dir = BASE_CAMERA_MODULE_PATH;
        if (spawnChild(camera) <= 0)
        {
            std::cerr << "CRITICAL: Failed to start de_camera. Exiting." << std::endl;
            stopAllChildren();
            return 1;
        }
        managed_children.push_back(camera);
        if (!waitModuleAlive(managed_children.back(), module_alive_sec))
        {
            std::cerr << "CRITICAL: de_camera failed during startup. Exiting." << std::endl;
            stopAllChildren();
            return 1;
        }
    }
    else
    {
        std::cout << "SKIPPING de_camera..." << std::endl;
    }

    // Step 10: Supervision loop - restart each crashed child alone with
    // backoff; the stack exits only after one child exceeds max restarts.
    while (!g_shutdown_requested)
    {
        bool stack_failed = false;
        int status;
        pid_t exited_pid;
        while ((exited_pid = waitpid(-1, &status, WNOHANG)) > 0)
        {
            if (!handleChildExit(exited_pid, status))
            {
                stack_failed = true;
            }
        }
        if (stack_failed)
        {
            preemptiveKill();
            return 1;
        }

        bool any_active = false;
        const auto now = std::chrono::steady_clock::now();
        for (auto &child : managed_children)
        {
            if (child.finished) continue;
            if (child.pending_restart && now >= child.restart_at)
            {
                std::cout << "Restarting " << child.name << "..." << std::endl;
                if (spawnChild(child) <= 0)
                {
                    child.pending_restart = false;
                    if (!scheduleRestart(child, "failed to restart"))
                    {
                        preemptiveKill();
                        return 1;
                    }
                }
            }
            if (child.pid > 0 || child.pending_restart) any_active = true;
        }
        if (!any_active)
        {
            std::cout << "All children finished. Exiting." << std::endl;
            return 0;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(SUPERVISOR_POLL_MS));
    }

    std::cout << "Shutdown requested. Stopping all children." << std::endl;
    preemptiveKill();
    return 0;
}
