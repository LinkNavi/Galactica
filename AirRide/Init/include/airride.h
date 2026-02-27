#pragma once
#include "service.h"
#include <atomic>
#include <map>
#include <mutex>
#include <vector>
#include <string>

#define AIRRIDE_SOCKET "/run/airride.sock"
#define SERVICES_DIR   "/etc/airride/services"
#define LOG_DIR        "/var/log/airride"

struct PendingRestart {
    std::string name;
    time_t      when;
};

class AirRide {
public:
    AirRide();
    void run();

private:
    std::map<std::string, Service> services;
    std::atomic<bool>              running{true};
    int                            control_socket = -1;
    int                            epoll_fd       = -1;
    std::mutex                     services_mutex;
    std::mutex                     pid_wait_mutex;
    std::vector<PendingRestart>    pending_restarts;

    void mount_filesystems();
    void set_hostname();
    void clear_console();

    bool parse_service_file(const std::string &filepath);
    void load_services();

    bool start_service(const std::string &name);
    bool start_service_internal(const std::string &name);
    bool stop_service(const std::string &name);
    void start_autostart_services();
    void wait_for_service(const std::string &name, int timeout_sec = 30);

    void setup_control_socket();
    void handle_control_commands();

    void reap_zombies();

    std::string get_service_status(const std::string &name);
    std::string list_services();

    static void log_service(const std::string &name, const std::string &msg);
};
