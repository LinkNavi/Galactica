#pragma once
#include <string>
#include <vector>
#include <map>
#include <sys/types.h>

enum class ServiceState { STOPPED, STARTING, RUNNING, STOPPING, FAILED };
enum class ServiceType  { SIMPLE, FORKING, ONESHOT };

struct Service {
    std::string name;
    std::string description;
    ServiceType  type            = ServiceType::SIMPLE;
    std::string  exec_start;
    std::string  exec_stop;
    std::string  tty_device;
    std::vector<std::string> requires_deps;
    std::vector<std::string> after;
    bool restart_on_failure = false;
    bool autostart          = false;
    bool parallel           = false;
    bool clear_screen       = false;
    bool foreground         = false;
    int  restart_delay      = 5;      // base delay (seconds)
    int  restart_delay_max  = 60;     // exponential backoff cap

    pid_t        pid     = 0;
    ServiceState state   = ServiceState::STOPPED;
    int          failures = 0;
};