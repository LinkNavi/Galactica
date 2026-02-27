#include "airride.h"
#include <algorithm>
#include <chrono>
#include <ctime>
#include <fcntl.h>
#include <iostream>
#include <sstream>
#include <thread>
#include <unistd.h>
#include <vector>

#ifdef __linux__
#include <sys/ioctl.h>
#include <sys/wait.h>
#endif

void AirRide::log_service(const std::string &name, const std::string &msg) {
    time_t now = time(nullptr);
    struct tm tm_info;
#ifdef __linux__
    localtime_r(&now, &tm_info);
#else
    tm_info = *localtime(&now);
#endif
    char ts[16];
    strftime(ts, sizeof(ts), "%H:%M:%S", &tm_info);

    std::string logpath = std::string(LOG_DIR) + "/" + name + ".log";
    int fd = open(logpath.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        std::string line = std::string("[") + ts + "] " + msg + "\n";
        (void)write(fd, line.c_str(), line.size());
        close(fd);
    }
}

void AirRide::wait_for_service(const std::string &name, int timeout_sec) {
    for (int i = 0; i < timeout_sec * 10; i++) {
        {
            std::lock_guard<std::mutex> lock(services_mutex);
            auto it = services.find(name);
            if (it == services.end()) return;
            auto state = it->second.state;
            auto type  = it->second.type;
            if (state == ServiceState::RUNNING) return;
            if (state == ServiceState::FAILED)  return;
            if (type == ServiceType::ONESHOT && state == ServiceState::STOPPED) return;
        }
        usleep(100000);
    }
    std::cerr << "[AirRide] Timeout waiting for dependency: " << name << std::endl;
}

bool AirRide::start_service_internal(const std::string &name) {
    Service svc_copy;
    {
        std::lock_guard<std::mutex> lock(services_mutex);
        auto it = services.find(name);
        if (it == services.end()) { std::cerr << "[AirRide] Service not found: " << name << std::endl; return false; }
        if (it->second.state == ServiceState::RUNNING || it->second.state == ServiceState::STARTING) return true;
        it->second.state = ServiceState::STARTING;
        svc_copy = it->second;
    }

    for (const auto &dep : svc_copy.requires_deps) {
        if (!start_service(dep)) {
            std::lock_guard<std::mutex> lock(services_mutex);
            auto it = services.find(name);
            if (it != services.end()) it->second.state = ServiceState::FAILED;
            std::cerr << "[AirRide] Required dependency failed: " << dep << std::endl;
            return false;
        }
    }
    for (const auto &dep : svc_copy.after)
        wait_for_service(dep, 10);

    std::cout << "[AirRide] Starting " << svc_copy.name;
    if (!svc_copy.tty_device.empty()) std::cout << " on " << svc_copy.tty_device;
    std::cout << std::endl;
    log_service(name, "Starting service");

#ifdef __linux__
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        std::string tty_path;
        if (!svc_copy.tty_device.empty()) tty_path = svc_copy.tty_device;
        else if (svc_copy.foreground)     tty_path = "/dev/console";

        if (!tty_path.empty()) {
            int fd = open(tty_path.c_str(), O_RDWR | O_NOCTTY);
            if (fd >= 0) { dup2(fd, 0); dup2(fd, 1); dup2(fd, 2); if (fd > 2) close(fd); ioctl(0, TIOCSCTTY, 1); }
        } else {
            std::string logfile = std::string(LOG_DIR) + "/" + svc_copy.name + ".log";
            int logfd  = open(logfile.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
            int nullfd = open("/dev/null", O_RDWR);
            if (nullfd >= 0) dup2(nullfd, 0);
            if (logfd  >= 0) { dup2(logfd, 1); dup2(logfd, 2); close(logfd); }
            else if (nullfd >= 0) { dup2(nullfd, 1); dup2(nullfd, 2); }
            if (nullfd >= 0 && nullfd > 2) close(nullfd);
        }

        std::vector<std::string> tokens;
        std::istringstream iss(svc_copy.exec_start);
        std::string tok;
        while (iss >> tok) tokens.push_back(tok);
        std::vector<char *> args;
        for (auto &t : tokens) args.push_back(&t[0]);
        args.push_back(nullptr);
        execvp(args[0], args.data());
        _exit(127);
    }

    if (pid > 0) {
        if (svc_copy.type == ServiceType::ONESHOT) {
            int status;
            { std::lock_guard<std::mutex> pw(pid_wait_mutex); waitpid(pid, &status, 0); }
            std::lock_guard<std::mutex> lock(services_mutex);
            auto it = services.find(name);
            if (it == services.end()) return false;
            it->second.pid = 0;
            bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
            it->second.state = ok ? ServiceState::STOPPED : ServiceState::FAILED;
            log_service(name, ok ? "Oneshot completed" : "Oneshot failed (exit " + std::to_string(WEXITSTATUS(status)) + ")");
            return ok;
        }
        std::lock_guard<std::mutex> lock(services_mutex);
        auto it = services.find(name);
        if (it != services.end()) { it->second.pid = pid; it->second.state = ServiceState::RUNNING; log_service(name, "Started (pid " + std::to_string(pid) + ")"); }
        return true;
    }
#endif

    std::lock_guard<std::mutex> lock(services_mutex);
    auto it = services.find(name);
    if (it != services.end()) it->second.state = ServiceState::FAILED;
    log_service(name, "fork() failed or unsupported platform");
    return false;
}

bool AirRide::start_service(const std::string &name) { return start_service_internal(name); }

bool AirRide::stop_service(const std::string &name) {
    pid_t pid_to_kill = 0;
    {
        std::lock_guard<std::mutex> lock(services_mutex);
        auto it = services.find(name);
        if (it == services.end()) return false;
        if (it->second.state != ServiceState::RUNNING) return true;
        it->second.state = ServiceState::STOPPING;
        pid_to_kill = it->second.pid;
    }

#ifdef __linux__
    if (pid_to_kill > 0) {
        kill(pid_to_kill, SIGTERM);
        bool exited = false;
        for (int i = 0; i < 50; i++) {
            usleep(100000);
            int status;
            if (waitpid(pid_to_kill, &status, WNOHANG) > 0) { exited = true; break; }
        }
        if (!exited) { kill(pid_to_kill, SIGKILL); waitpid(pid_to_kill, nullptr, 0); }
    }
#endif

    std::lock_guard<std::mutex> lock(services_mutex);
    auto it = services.find(name);
    if (it != services.end()) { it->second.pid = 0; it->second.state = ServiceState::STOPPED; }
    log_service(name, "Stopped");
    return true;
}

static const char *state_str(ServiceState s) {
    switch (s) {
        case ServiceState::STOPPED:  return "stopped";
        case ServiceState::STARTING: return "starting";
        case ServiceState::RUNNING:  return "running";
        case ServiceState::STOPPING: return "stopping";
        case ServiceState::FAILED:   return "failed";
    }
    return "unknown";
}

std::string AirRide::get_service_status(const std::string &name) {
    std::lock_guard<std::mutex> lock(services_mutex);
    auto it = services.find(name);
    if (it == services.end()) return "Service not found\n";
    const Service &svc = it->second;
    std::stringstream ss;
    ss << "Service:     " << svc.name        << "\n"
       << "Description: " << svc.description << "\n"
       << "State:       " << state_str(svc.state) << "\n";
    if (svc.pid > 0)             ss << "PID:         " << svc.pid          << "\n";
    if (!svc.tty_device.empty()) ss << "TTY:         " << svc.tty_device   << "\n";
    if (svc.failures > 0)        ss << "Failures:    " << svc.failures     << "\n";
    return ss.str();
}

std::string AirRide::list_services() {
    std::lock_guard<std::mutex> lock(services_mutex);
    std::stringstream ss;
    ss << "Services:\n";
    for (const auto &[name, svc] : services) {
        ss << "  " << name << " - " << state_str(svc.state);
        if (svc.autostart)           ss << " [auto]";
        if (!svc.tty_device.empty()) ss << " [" << svc.tty_device << "]";
        if (svc.failures > 0)        ss << " [failures:" << svc.failures << "]";
        ss << "\n";
    }
    return ss.str();
}

void AirRide::start_autostart_services() {
    std::cout << "[AirRide] Starting autostart services..." << std::endl;

    std::vector<std::string> parallel_svc, sequential_svc, tty_svc;
    {
        std::lock_guard<std::mutex> lock(services_mutex);
        for (auto &[name, svc] : services) {
            if (!svc.autostart) continue;
            if (!svc.tty_device.empty() || svc.foreground) tty_svc.push_back(name);
            else if (svc.parallel)                          parallel_svc.push_back(name);
            else                                            sequential_svc.push_back(name);
        }
    }

    std::vector<std::thread> threads;
    for (const auto &name : parallel_svc)
        threads.emplace_back([this, name]() { start_service_internal(name); });
    for (const auto &name : sequential_svc)
        start_service_internal(name);
    for (auto &t : threads) if (t.joinable()) t.join();

    clear_console();

    if (!tty_svc.empty()) {
        std::vector<std::thread> tty_threads;
        for (const auto &name : tty_svc)
            tty_threads.emplace_back([this, name]() { start_service_internal(name); });
        for (auto &t : tty_threads) if (t.joinable()) t.detach();
    } else {
        std::cout << "[AirRide] No TTY services, starting emergency shell" << std::endl;
        start_service("shell");
    }
}