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
#include <sys/ioctl.h>
#include <signal.h>
#include <fcntl.h>
#include <cstring>
#include <algorithm>
#include <dirent.h>
#include <thread>
#include <mutex>
#include <atomic>
#include <sys/sysmacros.h>

#define AIRRIDE_SOCKET "/run/airride.sock"
#define SERVICES_DIR "/etc/airride/services"
#define LOG_DIR "/var/log/airride"

enum class ServiceState { STOPPED, STARTING, RUNNING, STOPPING, FAILED };
enum class ServiceType { SIMPLE, FORKING, ONESHOT };

struct Service {
    std::string name;
    std::string description;
    ServiceType type = ServiceType::SIMPLE;
    std::string exec_start;
    std::string exec_stop;
    std::string tty_device;  // TTY device for this service
    std::vector<std::string> requires;
    std::vector<std::string> after;
    bool restart_on_failure = false;
    bool autostart = false;
    bool parallel = false;
    bool clear_screen = false;
    bool foreground = false;
    int restart_delay = 5;
    pid_t pid = 0;
    ServiceState state = ServiceState::STOPPED;
    int failures = 0;
};

class AirRide {
private:
    std::map<std::string, Service> services;
    std::atomic<bool> running{true};
    int control_socket = -1;
    std::mutex services_mutex;

    void mount_filesystems() {
        std::cout << "[AirRide] Mounting filesystems..." << std::endl;
        
        mkdir("/proc", 0755);
        mkdir("/sys", 0755);
        mkdir("/dev", 0755);
        mkdir("/run", 0755);
        mkdir("/tmp", 0755);
        mkdir("/dev/pts", 0755);
        mkdir("/dev/dri", 0755);
        mkdir(LOG_DIR, 0755);
        mkdir("/var/log", 0755);
        mkdir("/usr/share/udhcpc", 0755);
        
        mount("proc", "/proc", "proc", MS_NOEXEC | MS_NOSUID | MS_NODEV, nullptr);
        mount("sysfs", "/sys", "sysfs", MS_NOEXEC | MS_NOSUID | MS_NODEV, nullptr);
        mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
        mount("devpts", "/dev/pts", "devpts", 0, "gid=5,mode=620");
        mount("tmpfs", "/run", "tmpfs", MS_NOEXEC | MS_NOSUID | MS_NODEV, "mode=0755");
        mount("tmpfs", "/tmp", "tmpfs", MS_NOEXEC | MS_NOSUID | MS_NODEV, "mode=1777");
        
        // Create essential device nodes
        mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
        mknod("/dev/null", S_IFCHR | 0666, makedev(1, 3));
        mknod("/dev/zero", S_IFCHR | 0666, makedev(1, 5));
        mknod("/dev/random", S_IFCHR | 0666, makedev(1, 8));
        mknod("/dev/urandom", S_IFCHR | 0666, makedev(1, 9));
        mknod("/dev/tty", S_IFCHR | 0666, makedev(5, 0));
        mknod("/dev/tty0", S_IFCHR | 0620, makedev(4, 0));
        mknod("/dev/tty1", S_IFCHR | 0620, makedev(4, 1));
        mknod("/dev/tty2", S_IFCHR | 0620, makedev(4, 2));
        mknod("/dev/tty3", S_IFCHR | 0620, makedev(4, 3));
        mknod("/dev/ttyS0", S_IFCHR | 0660, makedev(4, 64));
        mknod("/dev/fb0", S_IFCHR | 0666, makedev(29, 0));
        mknod("/dev/dri/card0", S_IFCHR | 0666, makedev(226, 0));
        mknod("/dev/dri/renderD128", S_IFCHR | 0666, makedev(226, 128));
        
        // Set hostname early
        set_hostname();
        
        std::cout << "[AirRide] Filesystems ready" << std::endl;
    }

    void set_hostname() {
        std::ifstream hf("/etc/hostname");
        std::string hostname = "galactica";
        if (hf.is_open()) {
            std::getline(hf, hostname);
            hf.close();
        }
        if (!hostname.empty()) {
            sethostname(hostname.c_str(), hostname.length());
        }
    }

    void clear_console() {
        int fd = open("/dev/console", O_WRONLY);
        if (fd >= 0) {
            const char* clear = "\033[2J\033[H";
            write(fd, clear, strlen(clear));
            close(fd);
        }
        std::cout << "\033[2J\033[H" << std::flush;
    }

    bool parse_service_file(const std::string& filepath) {
        std::ifstream file(filepath);
        if (!file.is_open()) return false;

        Service svc;
        std::string line, current_section;

        while (std::getline(file, line)) {
            line.erase(0, line.find_first_not_of(" \t"));
            line.erase(line.find_last_not_of(" \t\r\n") + 1);
            
            if (line.empty() || line[0] == '#') continue;
            
            if (line[0] == '[' && line.back() == ']') {
                current_section = line.substr(1, line.length()-2);
                continue;
            }
            
            size_t eq = line.find('=');
            if (eq == std::string::npos) continue;
            
            std::string key = line.substr(0, eq);
            std::string value = line.substr(eq + 1);
            key.erase(key.find_last_not_of(" \t") + 1);
            value.erase(0, value.find_first_not_of(" \t"));
            
            if (value.length() >= 2 && value[0] == '"' && value.back() == '"')
                value = value.substr(1, value.length()-2);
            
            auto is_true = [](const std::string& v) {
                return v == "true" || v == "yes" || v == "1";
            };
            
            if (current_section == "Service") {
                if (key == "name") svc.name = value;
                else if (key == "description") svc.description = value;
                else if (key == "exec_start") svc.exec_start = value;
                else if (key == "exec_stop") svc.exec_stop = value;
                else if (key == "tty") svc.tty_device = value;
                else if (key == "autostart") svc.autostart = is_true(value);
                else if (key == "parallel") svc.parallel = is_true(value);
                else if (key == "clear_screen") svc.clear_screen = is_true(value);
                else if (key == "foreground") svc.foreground = is_true(value);
                else if (key == "type") {
                    if (value == "simple") svc.type = ServiceType::SIMPLE;
                    else if (value == "forking") svc.type = ServiceType::FORKING;
                    else if (value == "oneshot") svc.type = ServiceType::ONESHOT;
                }
                else if (key == "restart") svc.restart_on_failure = (value == "on-failure" || value == "always");
                else if (key == "restart_delay") svc.restart_delay = std::stoi(value);
            }
            else if (current_section == "Dependencies") {
                if (key == "requires" || key == "after") {
                    std::vector<std::string>& target = (key == "requires") ? svc.requires : svc.after;
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

    void load_services() {
        std::cout << "[AirRide] Loading services..." << std::endl;
        
        // Emergency shell - always available
        Service shell;
        shell.name = "shell";
        shell.description = "Emergency Shell";
        shell.type = ServiceType::SIMPLE;
        shell.exec_start = "/bin/sh";
        shell.foreground = true;
        services["shell"] = shell;
        
        // Scan services directory
        DIR* dir = opendir(SERVICES_DIR);
        if (dir) {
            struct dirent* entry;
            while ((entry = readdir(dir)) != nullptr) {
                std::string fname = entry->d_name;
                if (fname.length() > 8 && fname.substr(fname.length()-8) == ".service") {
                    std::string path = std::string(SERVICES_DIR) + "/" + fname;
                    parse_service_file(path);
                }
            }
            closedir(dir);
        }
        
        std::cout << "[AirRide] " << services.size() << " services loaded" << std::endl;
    }

    void wait_for_service(const std::string& name, int timeout_sec = 30) {
        for (int i = 0; i < timeout_sec * 10; i++) {
            {
                std::lock_guard<std::mutex> lock(services_mutex);
                auto it = services.find(name);
                if (it != services.end()) {
                    auto state = it->second.state;
                    auto type = it->second.type;
                    
                    if (state == ServiceState::RUNNING) return;
                    if (state == ServiceState::FAILED) return;
                    if (type == ServiceType::ONESHOT && state == ServiceState::STOPPED) return;
                }
            }
            usleep(100000);
        }
    }

    bool start_service_internal(const std::string& name) {
        Service* svc = nullptr;
        {
            std::lock_guard<std::mutex> lock(services_mutex);
            auto it = services.find(name);
            if (it == services.end()) {
                std::cerr << "[AirRide] Service not found: " << name << std::endl;
                return false;
            }
            svc = &it->second;
            
            if (svc->state == ServiceState::RUNNING) return true;
            if (svc->state == ServiceState::STARTING) return true;
            
            svc->state = ServiceState::STARTING;
        }

        // Start dependencies first
        for (const auto& dep : svc->requires) {
            if (!start_service(dep)) {
                std::lock_guard<std::mutex> lock(services_mutex);
                svc->state = ServiceState::FAILED;
                return false;
            }
        }

        // Wait for 'after' dependencies
        for (const auto& dep : svc->after) {
            wait_for_service(dep, 10);
        }

        std::cout << "[AirRide] Starting " << svc->name;
        if (!svc->tty_device.empty()) {
            std::cout << " on " << svc->tty_device;
        }
        std::cout << std::endl;

        pid_t pid = fork();
        if (pid == 0) {
            // Child process
            setsid();
            
            // Determine which TTY to use
            std::string tty_path;
            if (!svc->tty_device.empty()) {
                tty_path = svc->tty_device;
            } else if (svc->foreground) {
                tty_path = "/dev/console";
            }
            
            if (!tty_path.empty()) {
                // Open TTY for this service
                int fd = open(tty_path.c_str(), O_RDWR | O_NOCTTY);
                if (fd >= 0) {
                    dup2(fd, 0);
                    dup2(fd, 1);
                    dup2(fd, 2);
                    if (fd > 2) close(fd);
                    ioctl(0, TIOCSCTTY, 1);
                }
            } else {
                // Background service - redirect to log file
                std::string logfile = std::string(LOG_DIR) + "/" + svc->name + ".log";
                int logfd = open(logfile.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
                int nullfd = open("/dev/null", O_RDWR);
                
                if (nullfd >= 0) dup2(nullfd, 0);
                if (logfd >= 0) {
                    dup2(logfd, 1);
                    dup2(logfd, 2);
                    close(logfd);
                } else if (nullfd >= 0) {
                    dup2(nullfd, 1);
                    dup2(nullfd, 2);
                }
                if (nullfd >= 0 && nullfd > 2) close(nullfd);
            }
            
            // Parse and execute command
            std::vector<char*> args;
            std::vector<std::string> tokens;
            std::istringstream iss(svc->exec_start);
            std::string token;
            while (iss >> token) tokens.push_back(token);
            for (auto& t : tokens) args.push_back(&t[0]);
            args.push_back(nullptr);
            
            execvp(args[0], args.data());
            _exit(127);
        } else if (pid > 0) {
            std::lock_guard<std::mutex> lock(services_mutex);
            svc->pid = pid;
            svc->state = ServiceState::RUNNING;
            
            // For oneshot services, wait for completion
            if (svc->type == ServiceType::ONESHOT) {
                services_mutex.unlock();
                
                int status;
                waitpid(pid, &status, 0);
                
                services_mutex.lock();
                svc->pid = 0;
                if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                    svc->state = ServiceState::STOPPED;
                    std::cout << "[AirRide] " << svc->name << " completed" << std::endl;
                } else {
                    svc->state = ServiceState::FAILED;
                    std::cerr << "[AirRide] " << svc->name << " failed" << std::endl;
                    return false;
                }
            }
            return true;
        }
        
        std::lock_guard<std::mutex> lock(services_mutex);
        svc->state = ServiceState::FAILED;
        return false;
    }

    bool start_service(const std::string& name) {
        return start_service_internal(name);
    }

    bool stop_service(const std::string& name) {
        std::lock_guard<std::mutex> lock(services_mutex);
        auto it = services.find(name);
        if (it == services.end()) return false;

        Service& svc = it->second;
        if (svc.state != ServiceState::RUNNING) return true;

        std::cout << "[AirRide] Stopping " << svc.name << std::endl;
        svc.state = ServiceState::STOPPING;

        if (svc.pid > 0) {
            kill(svc.pid, SIGTERM);
            
            services_mutex.unlock();
            for (int i = 0; i < 50; i++) {
                usleep(100000);
                int status;
                if (waitpid(svc.pid, &status, WNOHANG) > 0) {
                    break;
                }
            }
            services_mutex.lock();
            
            if (svc.pid > 0) {
                kill(svc.pid, SIGKILL);
                waitpid(svc.pid, nullptr, 0);
            }
            svc.pid = 0;
        }

        svc.state = ServiceState::STOPPED;
        return true;
    }

    std::string get_service_status(const std::string& name) {
        std::lock_guard<std::mutex> lock(services_mutex);
        auto it = services.find(name);
        if (it == services.end()) return "Service not found\n";

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
        if (svc.pid > 0) ss << "PID: " << svc.pid << "\n";
        if (!svc.tty_device.empty()) ss << "TTY: " << svc.tty_device << "\n";
        return ss.str();
    }

    std::string list_services() {
        std::lock_guard<std::mutex> lock(services_mutex);
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
            if (svc.autostart) ss << " [auto]";
            if (!svc.tty_device.empty()) ss << " [" << svc.tty_device << "]";
            ss << "\n";
        }
        return ss.str();
    }

    void setup_control_socket() {
        control_socket = socket(AF_UNIX, SOCK_STREAM, 0);
        if (control_socket == -1) return;

        unlink(AIRRIDE_SOCKET);

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, AIRRIDE_SOCKET, sizeof(addr.sun_path) - 1);

        if (bind(control_socket, (struct sockaddr*)&addr, sizeof(addr)) == -1 ||
            listen(control_socket, 5) == -1) {
            close(control_socket);
            control_socket = -1;
            return;
        }

        fcntl(control_socket, F_SETFL, fcntl(control_socket, F_GETFL, 0) | O_NONBLOCK);
    }

    void handle_control_commands() {
        if (control_socket == -1) return;

        int client = accept(control_socket, nullptr, nullptr);
        if (client == -1) return;

        char buffer[1024];
        ssize_t n = read(client, buffer, sizeof(buffer) - 1);
        if (n > 0) {
            buffer[n] = '\0';
            std::istringstream iss(buffer);
            std::string cmd, svc_name;
            iss >> cmd >> svc_name;

            std::string response;
            if (cmd == "start") response = start_service(svc_name) ? "OK\n" : "FAILED\n";
            else if (cmd == "stop") response = stop_service(svc_name) ? "OK\n" : "FAILED\n";
            else if (cmd == "restart") {
                stop_service(svc_name);
                usleep(500000);
                response = start_service(svc_name) ? "OK\n" : "FAILED\n";
            }
            else if (cmd == "status") response = get_service_status(svc_name);
            else if (cmd == "list") response = list_services();
            else response = "Unknown command\n";

            write(client, response.c_str(), response.length());
        }
        close(client);
    }

    void reap_zombies() {
        int status;
        pid_t pid;
        while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
            std::lock_guard<std::mutex> lock(services_mutex);
            for (auto& [name, svc] : services) {
                if (svc.pid == pid) {
                    bool success = WIFEXITED(status) && WEXITSTATUS(status) == 0;
                    svc.state = success ? ServiceState::STOPPED : ServiceState::FAILED;
                    svc.pid = 0;
                    
                    std::cout << "[AirRide] Service " << name << " exited" << std::endl;
                    
                    // Auto-restart if configured
                    if (svc.restart_on_failure && svc.failures < 10) {
                        svc.failures++;
                        std::string svc_name = name;
                        int delay = svc.restart_delay;
                        std::thread([this, svc_name, delay]() {
                            sleep(delay);
                            start_service(svc_name);
                        }).detach();
                    }
                    break;
                }
            }
        }
    }

    void start_autostart_services() {
        std::cout << "[AirRide] Starting services..." << std::endl;
        
        std::vector<std::string> parallel_services;
        std::vector<std::string> sequential_services;
        std::vector<std::string> tty_services;
        
        {
            std::lock_guard<std::mutex> lock(services_mutex);
            for (auto& [name, svc] : services) {
                if (!svc.autostart) continue;
                
                // TTY services (like login prompts) start last
                if (!svc.tty_device.empty() || svc.foreground) {
                    tty_services.push_back(name);
                } else if (svc.parallel) {
                    parallel_services.push_back(name);
                } else {
                    sequential_services.push_back(name);
                }
            }
        }
        
        // Start parallel services in threads
        std::vector<std::thread> threads;
        for (const auto& name : parallel_services) {
            threads.emplace_back([this, name]() {
                start_service_internal(name);
            });
        }
        
        // Start sequential services
        for (const auto& name : sequential_services) {
            start_service_internal(name);
        }
        
        // Wait for all parallel services
        for (auto& t : threads) {
            if (t.joinable()) t.join();
        }
        
        // Wait for network to settle
        usleep(500000);
        
        // Clear screen before TTY services
        clear_console();
        
        // Start TTY services (login prompts)
        if (!tty_services.empty()) {
            for (const auto& name : tty_services) {
                start_service_internal(name);
            }
        } else {
            std::cout << "[AirRide] No TTY services, starting emergency shell" << std::endl;
            start_service("shell");
        }
    }

public:
    AirRide() {
        signal(SIGCHLD, SIG_DFL);
    }

    void run() {
        clear_console();
        std::cout << "=== AirRide Init System ===" << std::endl;
        std::cout << "[AirRide] PID " << getpid() << std::endl;

        if (getpid() == 1) {
            mount_filesystems();
        } else {
            std::cout << "[AirRide] Test mode" << std::endl;
        }

        setup_control_socket();
        load_services();
        start_autostart_services();

        while (running) {
            handle_control_commands();
            reap_zombies();
            usleep(100000);
        }

        if (control_socket != -1) {
            close(control_socket);
            unlink(AIRRIDE_SOCKET);
        }
    }
};

int main() {
    AirRide init;
    init.run();
    return 0;
}
