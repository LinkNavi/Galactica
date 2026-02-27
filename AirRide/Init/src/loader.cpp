#include "airride.h"
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <sstream>
#include <mutex>

bool AirRide::parse_service_file(const std::string &filepath) {
    std::ifstream file(filepath);
    if (!file.is_open()) return false;

    Service svc;
    std::string line, section;

    while (std::getline(file, line)) {
        // Strip whitespace
        line.erase(0, line.find_first_not_of(" \t"));
        line.erase(line.find_last_not_of(" \t\r\n") + 1);

        if (line.empty() || line[0] == '#') continue;

        if (line[0] == '[' && line.back() == ']') {
            section = line.substr(1, line.length() - 2);
            continue;
        }

        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;

        std::string key   = line.substr(0, eq);
        std::string value = line.substr(eq + 1);
        key.erase(key.find_last_not_of(" \t") + 1);
        value.erase(0, value.find_first_not_of(" \t"));

        if (value.length() >= 2 && value[0] == '"' && value.back() == '"')
            value = value.substr(1, value.length() - 2);

        auto is_true = [](const std::string &v) {
            return v == "true" || v == "yes" || v == "1";
        };

        if (section == "Service") {
            if      (key == "name")          svc.name        = value;
            else if (key == "description")   svc.description = value;
            else if (key == "exec_start")    svc.exec_start  = value;
            else if (key == "exec_stop")     svc.exec_stop   = value;
            else if (key == "tty")           svc.tty_device  = value;
            else if (key == "autostart")     svc.autostart   = is_true(value);
            else if (key == "parallel")      svc.parallel    = is_true(value);
            else if (key == "clear_screen")  svc.clear_screen = is_true(value);
            else if (key == "foreground")    svc.foreground  = is_true(value);
            else if (key == "restart_delay_max")
                svc.restart_delay_max = std::stoi(value);
            else if (key == "restart_delay")
                svc.restart_delay = std::stoi(value);
            else if (key == "type") {
                if      (value == "simple")  svc.type = ServiceType::SIMPLE;
                else if (value == "forking") svc.type = ServiceType::FORKING;
                else if (value == "oneshot") svc.type = ServiceType::ONESHOT;
            }
            else if (key == "restart")
                svc.restart_on_failure = (value == "on-failure" || value == "always");
        }
        else if (section == "Dependencies") {
            if (key == "requires" || key == "after") {
                auto &target = (key == "requires") ? svc.requires_deps : svc.after;
                std::istringstream ss(value);
                std::string dep;
                while (ss >> dep) target.push_back(dep);
            }
        }
    }

    if (!svc.name.empty()) {
        std::lock_guard<std::mutex> lock(services_mutex);
        services[svc.name] = svc;
        return true;
    }
    return false;
}

void AirRide::load_services() {
    std::cout << "[AirRide] Loading services..." << std::endl;

    // Built-in emergency shell — always available
    Service shell;
    shell.name        = "shell";
    shell.description = "Emergency Shell";
    shell.type        = ServiceType::SIMPLE;
    shell.exec_start  = "/bin/sh";
    shell.foreground  = true;
    services["shell"] = shell;

    DIR *dir = opendir(SERVICES_DIR);
    if (dir) {
        struct dirent *entry;
        while ((entry = readdir(dir)) != nullptr) {
            std::string fname = entry->d_name;
            if (fname.length() > 8 &&
                fname.substr(fname.length() - 8) == ".service") {
                parse_service_file(std::string(SERVICES_DIR) + "/" + fname);
            }
        }
        closedir(dir);
    }

    std::cout << "[AirRide] " << services.size() << " services loaded" << std::endl;
}