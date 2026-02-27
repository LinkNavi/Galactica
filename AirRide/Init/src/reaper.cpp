#ifdef __linux__
#include "airride.h"
#include <algorithm>
#include <iostream>
#include <sys/wait.h>

void AirRide::reap_zombies() {
    int status;
    pid_t pid;

    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        std::string exited_name;
        bool should_restart = false;
        int  base_delay = 5, max_delay = 60, failures = 0;

        {
            std::lock_guard<std::mutex> lock(services_mutex);
            for (auto &[name, svc] : services) {
                if (svc.pid != pid) continue;
                bool success = WIFEXITED(status) && WEXITSTATUS(status) == 0;
                svc.state = success ? ServiceState::STOPPED : ServiceState::FAILED;
                svc.pid   = 0;
                std::cout << "[AirRide] Service " << name << " exited ("
                          << (success ? "clean" : "failed") << ")" << std::endl;
                if (svc.restart_on_failure && svc.failures < 10) {
                    svc.failures++;
                    exited_name    = name;
                    should_restart = true;
                    base_delay     = svc.restart_delay;
                    max_delay      = svc.restart_delay_max;
                    failures       = svc.failures;
                } else if (svc.failures >= 10) {
                    std::cerr << "[AirRide] " << name << " exceeded max restarts" << std::endl;
                    log_service(name, "Exceeded max restart attempts (10), stopped");
                }
                break;
            }
        }

        if (should_restart) {
            int delay = base_delay;
            for (int i = 1; i < failures; i++) { delay *= 2; if (delay >= max_delay) { delay = max_delay; break; } }
            pending_restarts.push_back({exited_name, time(nullptr) + delay});
            log_service(exited_name, "Scheduled restart in " + std::to_string(delay) + "s (attempt " + std::to_string(failures) + ")");
            std::cout << "[AirRide] Restarting " << exited_name << " in " << delay << "s" << std::endl;
        }
    }

    time_t now = time(nullptr);
    pending_restarts.erase(
        std::remove_if(pending_restarts.begin(), pending_restarts.end(),
            [&](const PendingRestart &r) {
                if (now >= r.when) { start_service(r.name); return true; }
                return false;
            }),
        pending_restarts.end());
}

#else
#include "airride.h"
void AirRide::reap_zombies() {}
#endif