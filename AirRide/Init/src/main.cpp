#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#include <fcntl.h>
#include <cstring>
#include <algorithm>

#define AIRRIDE_SOCKET "/run/airride.sock"

// Service states
enum class ServiceState {
    STOPPED,
    STARTING,
    RUNNING,
    STOPPING,
    FAILED
};

// Service types
enum class ServiceType {
    SIMPLE,    // Process runs in foreground
    FORKING,   // Process forks to background
    ONESHOT    // Runs once and exits
};

// Service definition
struct Service {
    std::string name;
    std::string description;
    ServiceType type = ServiceType::SIMPLE;
    std::string exec_start;
    std::string exec_stop;
    std::vector<std::string> requires;  // Must start before this
    std::vector<std::string> after;     // Prefer to start after these
    bool restart_on_failure = false;
    int restart_delay = 5;
    pid_t pid = 0;
    ServiceState state = ServiceState::STOPPED;
    int failures = 0;
};

// Control commands
enum class Command {
    START,
    STOP,
    RESTART,
    STATUS,
    LIST,
    UNKNOWN
};

class AirRide {
private:
    std::map<std::string, Service> services;
    bool running = true;
    int control_socket = -1;

    // Mount essential filesystems
    void mount_filesystems() {
        std::cout << "[AirRide] Mounting essential filesystems..." << std::endl;
        
        // Create mount points if they don't exist
        mkdir("/proc", 0755);
        mkdir("/sys", 0755);
        mkdir("/dev", 0755);
        mkdir("/run", 0755);
        mkdir("/tmp", 0755);
        
        // Mount virtual filesystems
        if (mount("proc", "/proc", "proc", MS_NOEXEC | MS_NOSUID | MS_NODEV, nullptr) == -1) {
            std::cerr << "[AirRide] Warning: Failed to mount /proc" << std::endl;
        }
        
        if (mount("sysfs", "/sys", "sysfs", MS_NOEXEC | MS_NOSUID | MS_NODEV, nullptr) == -1) {
            std::cerr << "[AirRide] Warning: Failed to mount /sys" << std::endl;
        }
        
        if (mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755") == -1) {
            std::cerr << "[AirRide] Warning: Failed to mount /dev" << std::endl;
        }
        
        if (mount("tmpfs", "/run", "tmpfs", MS_NOEXEC | MS_NOSUID | MS_NODEV, "mode=0755") == -1) {
            std::cerr << "[AirRide] Warning: Failed to mount /run" << std::endl;
        }
        
        if (mount("tmpfs", "/tmp", "tmpfs", MS_NOEXEC | MS_NOSUID | MS_NODEV, "mode=1777") == -1) {
            std::cerr << "[AirRide] Warning: Failed to mount /tmp" << std::endl;
        }
        
        std::cout << "[AirRide] Filesystems mounted" << std::endl;
    }

    // Parse a simple service file
    bool parse_service_file(const std::string& filepath) {
        std::ifstream file(filepath);
        if (!file.is_open()) {
            return false;
        }

        Service svc;
        std::string line;
        std::string current_section;

        while (std::getline(file, line)) {
            // Remove leading/trailing whitespace
            line.erase(0, line.find_first_not_of(" \t"));
            line.erase(line.find_last_not_of(" \t") + 1);
            
            // Skip empty lines and comments
            if (line.empty() || line[0] == '#') continue;
            
            // Check for section headers
            if (line[0] == '[' && line[line.length()-1] == ']') {
                current_section = line.substr(1, line.length()-2);
                continue;
            }
            
            // Parse key=value pairs
            size_t eq_pos = line.find('=');
            if (eq_pos == std::string::npos) continue;
            
            std::string key = line.substr(0, eq_pos);
            std::string value = line.substr(eq_pos + 1);
            
            // Trim key and value
            key.erase(0, key.find_first_not_of(" \t"));
            key.erase(key.find_last_not_of(" \t") + 1);
            value.erase(0, value.find_first_not_of(" \t"));
            value.erase(value.find_last_not_of(" \t") + 1);
            
            // Remove quotes from value
            if (value.length() >= 2 && value[0] == '"' && value[value.length()-1] == '"') {
                value = value.substr(1, value.length()-2);
            }
            
            // Process based on section and key
            if (current_section == "Service") {
                if (key == "name") svc.name = value;
                else if (key == "description") svc.description = value;
                else if (key == "exec_start") svc.exec_start = value;
                else if (key == "exec_stop") svc.exec_stop = value;
                else if (key == "type") {
                    if (value == "simple") svc.type = ServiceType::SIMPLE;
                    else if (value == "forking") svc.type = ServiceType::FORKING;
                    else if (value == "oneshot") svc.type = ServiceType::ONESHOT;
                }
                else if (key == "restart") {
                    svc.restart_on_failure = (value == "on-failure" || value == "always");
                }
                else if (key == "restart_delay") {
                    svc.restart_delay = std::stoi(value);
                }
            }
            else if (current_section == "Dependencies") {
                if (key == "requires" || key == "after") {
                    std::vector<std::string>& target = (key == "requires") ? svc.requires : svc.after;
                    std::stringstream ss(value);
                    std::string dep;
                    while (ss >> dep) {
                        target.push_back(dep);
                    }
                }
            }
        }

        if (!svc.name.empty()) {
            services[svc.name] = svc;
            return true;
        }
        return false;
    }

    // Load all service files from directory
    void load_services(const std::string& services_dir) {
        std::cout << "[AirRide] Loading services from " << services_dir << std::endl;
        
        // In a real implementation, you'd scan the directory
        // For now, we'll create some default services programmatically
        
        // Shell service (always available)
        Service shell;
        shell.name = "shell";
        shell.description = "Emergency Shell";
        shell.type = ServiceType::SIMPLE;
        shell.exec_start = "/bin/sh";
        services["shell"] = shell;
    }

    // Start a service
    bool start_service(const std::string& name) {
        auto it = services.find(name);
        if (it == services.end()) {
            std::cerr << "[AirRide] Service " << name << " not found" << std::endl;
            return false;
        }

        Service& svc = it->second;
        
        if (svc.state == ServiceState::RUNNING) {
            return true;  // Already running
        }

        std::cout << "[AirRide] Starting " << svc.name << ": " << svc.description << std::endl;
        svc.state = ServiceState::STARTING;

        // Start dependencies first
        for (const auto& dep : svc.requires) {
            if (!start_service(dep)) {
                std::cerr << "[AirRide] Failed to start dependency: " << dep << std::endl;
                svc.state = ServiceState::FAILED;
                return false;
            }
        }

        // Fork and execute
        pid_t pid = fork();
        if (pid == 0) {
            // Child process
            // Parse command and arguments
            std::vector<char*> args;
            std::istringstream iss(svc.exec_start);
            std::vector<std::string> tokens;
            std::string token;
            while (iss >> token) {
                tokens.push_back(token);
            }
            
            for (auto& t : tokens) {
                args.push_back(&t[0]);
            }
            args.push_back(nullptr);
            
            // Execute
            execvp(args[0], args.data());
            
            // If exec fails
            std::cerr << "[AirRide] Failed to exec: " << svc.exec_start << std::endl;
            exit(1);
        } else if (pid > 0) {
            // Parent process
            svc.pid = pid;
            svc.state = ServiceState::RUNNING;
            std::cout << "[AirRide] Started " << svc.name << " (PID: " << pid << ")" << std::endl;
            return true;
        } else {
            std::cerr << "[AirRide] Fork failed for service: " << svc.name << std::endl;
            svc.state = ServiceState::FAILED;
            return false;
        }
    }

    // Stop a service
    bool stop_service(const std::string& name) {
        auto it = services.find(name);
        if (it == services.end()) {
            std::cerr << "[AirRide] Service " << name << " not found" << std::endl;
            return false;
        }

        Service& svc = it->second;
        
        if (svc.state != ServiceState::RUNNING) {
            std::cout << "[AirRide] Service " << name << " is not running" << std::endl;
            return true;
        }

        std::cout << "[AirRide] Stopping " << svc.name << std::endl;
        svc.state = ServiceState::STOPPING;

        if (svc.pid > 0) {
            kill(svc.pid, SIGTERM);
            
            // Wait for process to exit (with timeout)
            int timeout = 10;
            while (timeout > 0 && svc.pid > 0) {
                sleep(1);
                timeout--;
                reap_zombies();
            }
            
            // Force kill if still running
            if (svc.pid > 0) {
                std::cout << "[AirRide] Force killing " << svc.name << std::endl;
                kill(svc.pid, SIGKILL);
            }
        }

        svc.state = ServiceState::STOPPED;
        return true;
    }

    // Get service status
    std::string get_service_status(const std::string& name) {
        auto it = services.find(name);
        if (it == services.end()) {
            return "Service not found";
        }

        Service& svc = it->second;
        std::stringstream ss;
        ss << "Service: " << svc.name << "\n";
        ss << "Description: " << svc.description << "\n";
        ss << "State: ";
        
        switch (svc.state) {
            case ServiceState::STOPPED: ss << "stopped"; break;
            case ServiceState::STARTING: ss << "starting"; break;
            case ServiceState::RUNNING: ss << "running"; break;
            case ServiceState::STOPPING: ss << "stopping"; break;
            case ServiceState::FAILED: ss << "failed"; break;
        }
        
        ss << "\n";
        if (svc.pid > 0) {
            ss << "PID: " << svc.pid << "\n";
        }
        
        return ss.str();
    }

    // List all services
    std::string list_services() {
        std::stringstream ss;
        ss << "Services:\n";
        for (const auto& [name, svc] : services) {
            ss << "  " << name << " - ";
            switch (svc.state) {
                case ServiceState::STOPPED: ss << "stopped"; break;
                case ServiceState::STARTING: ss << "starting"; break;
                case ServiceState::RUNNING: ss << "running"; break;
                case ServiceState::STOPPING: ss << "stopping"; break;
                case ServiceState::FAILED: ss << "failed"; break;
            }
            ss << "\n";
        }
        return ss.str();
    }

    // Setup control socket
    void setup_control_socket() {
        control_socket = socket(AF_UNIX, SOCK_STREAM, 0);
        if (control_socket == -1) {
            std::cerr << "[AirRide] Failed to create control socket" << std::endl;
            return;
        }

        // Remove old socket if exists
        unlink(AIRRIDE_SOCKET);

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, AIRRIDE_SOCKET, sizeof(addr.sun_path) - 1);

        if (bind(control_socket, (struct sockaddr*)&addr, sizeof(addr)) == -1) {
            std::cerr << "[AirRide] Failed to bind control socket" << std::endl;
            close(control_socket);
            control_socket = -1;
            return;
        }

        if (listen(control_socket, 5) == -1) {
            std::cerr << "[AirRide] Failed to listen on control socket" << std::endl;
            close(control_socket);
            control_socket = -1;
            return;
        }

        // Make socket non-blocking
        int flags = fcntl(control_socket, F_GETFL, 0);
        fcntl(control_socket, F_SETFL, flags | O_NONBLOCK);

        std::cout << "[AirRide] Control socket ready at " << AIRRIDE_SOCKET << std::endl;
    }

    // Handle control commands
    void handle_control_commands() {
        if (control_socket == -1) return;

        int client = accept(control_socket, nullptr, nullptr);
        if (client == -1) return;

        char buffer[1024];
        ssize_t n = read(client, buffer, sizeof(buffer) - 1);
        if (n > 0) {
            buffer[n] = '\0';
            std::string cmd(buffer);
            
            std::istringstream iss(cmd);
            std::string command, service;
            iss >> command >> service;

            std::string response;
            
            if (command == "start") {
                bool success = start_service(service);
                response = success ? "OK\n" : "FAILED\n";
            } else if (command == "stop") {
                bool success = stop_service(service);
                response = success ? "OK\n" : "FAILED\n";
            } else if (command == "restart") {
                stop_service(service);
                sleep(1);
                bool success = start_service(service);
                response = success ? "OK\n" : "FAILED\n";
            } else if (command == "status") {
                response = get_service_status(service);
            } else if (command == "list") {
                response = list_services();
            } else {
                response = "Unknown command\n";
            }

            write(client, response.c_str(), response.length());
        }

        close(client);
    }

    // Reap zombie processes
    void reap_zombies() {
        int status;
        pid_t pid;
        
        while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
            // Find which service this PID belonged to
            for (auto& [name, svc] : services) {
                if (svc.pid == pid) {
                    if (WIFEXITED(status)) {
                        int exit_code = WEXITSTATUS(status);
                        std::cout << "[AirRide] Service " << svc.name << " exited with code " 
                                  << exit_code << std::endl;
                        
                        if (exit_code != 0) {
                            svc.state = ServiceState::FAILED;
                            svc.failures++;
                            
                            // Restart if configured
                            if (svc.restart_on_failure && svc.failures < 5) {
                                std::cout << "[AirRide] Will restart " << svc.name 
                                          << " in " << svc.restart_delay << " seconds" << std::endl;
                                // In real implementation, schedule restart
                            }
                        } else {
                            svc.state = ServiceState::STOPPED;
                        }
                    } else if (WIFSIGNALED(status)) {
                        std::cout << "[AirRide] Service " << svc.name << " killed by signal " 
                                  << WTERMSIG(status) << std::endl;
                        svc.state = ServiceState::FAILED;
                    }
                    svc.pid = 0;
                    break;
                }
            }
        }
    }

    // Signal handler
    static void signal_handler(int sig) {
        if (sig == SIGCHLD) {
            // Handled in main loop
        }
    }

public:
    AirRide() {
        // Set up signal handlers
        signal(SIGCHLD, signal_handler);
    }

    void run() {
        std::cout << "=== AirRide Init System ===" << std::endl;
        std::cout << "[AirRide] PID: " << getpid() << std::endl;

        // Check if we're PID 1
        if (getpid() != 1) {
            std::cout << "[AirRide] Warning: Not running as PID 1, running in test mode" << std::endl;
        }

        // Mount filesystems
        if (getpid() == 1) {
            mount_filesystems();
        }

        // Setup control socket
        setup_control_socket();

        // Load service definitions
        load_services("/etc/airride/services");

        // Start default services
        std::cout << "[AirRide] Starting default services..." << std::endl;
        
        // Start shell (for now, just to have something running)
        start_service("shell");

        std::cout << "[AirRide] System initialized. Use 'airridectl' to manage services." << std::endl;

        // Main loop
        while (running) {
            // Handle control commands
            handle_control_commands();
            
            // Reap any zombie processes
            reap_zombies();
            
            // Sleep briefly to avoid burning CPU
            usleep(100000);  // 100ms
        }

        std::cout << "[AirRide] Shutting down..." << std::endl;
        if (control_socket != -1) {
            close(control_socket);
            unlink(AIRRIDE_SOCKET);
        }
    }

    void shutdown() {
        running = false;
    }
};

int main(int argc, char* argv[]) {
    AirRide init;
    init.run();
    return 0;
}
