#include <iostream>
#include <string>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define AIRRIDE_SOCKET "/run/airride.sock"

class AirRideCtl {
private:
    int sock = -1;

    bool connect_to_airride() {
        sock = socket(AF_UNIX, SOCK_STREAM, 0);
        if (sock == -1) {
            std::cerr << "Error: Failed to create socket" << std::endl;
            return false;
        }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, AIRRIDE_SOCKET, sizeof(addr.sun_path) - 1);

        if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) == -1) {
            std::cerr << "Error: Cannot connect to AirRide. Is it running?" << std::endl;
            close(sock);
            sock = -1;
            return false;
        }

        return true;
    }

    std::string send_command(const std::string& cmd) {
        if (!connect_to_airride()) {
            return "";
        }

        // Send command
        if (write(sock, cmd.c_str(), cmd.length()) == -1) {
            std::cerr << "Error: Failed to send command" << std::endl;
            close(sock);
            return "";
        }

        // Receive response
        char buffer[4096];
        ssize_t n = read(sock, buffer, sizeof(buffer) - 1);
        close(sock);

        if (n > 0) {
            buffer[n] = '\0';
            return std::string(buffer);
        }

        return "";
    }

    void print_usage(const std::string& prog) {
        std::cout << "Usage: " << prog << " <command> [service]\n\n";
        std::cout << "Commands:\n";
        std::cout << "  start <service>    Start a service\n";
        std::cout << "  stop <service>     Stop a service\n";
        std::cout << "  restart <service>  Restart a service\n";
        std::cout << "  status <service>   Show service status\n";
        std::cout << "  list               List all services\n";
        std::cout << "\nExamples:\n";
        std::cout << "  " << prog << " start sshd\n";
        std::cout << "  " << prog << " status network\n";
        std::cout << "  " << prog << " list\n";
    }

public:
    int run(int argc, char* argv[]) {
        if (argc < 2) {
            print_usage(argv[0]);
            return 1;
        }

        std::string command = argv[1];

        // Handle list command (no service name needed)
        if (command == "list") {
            std::string response = send_command("list");
            if (!response.empty()) {
                std::cout << response;
                return 0;
            }
            return 1;
        }

        // Other commands need a service name
        if (argc < 3) {
            std::cerr << "Error: Service name required for '" << command << "' command\n\n";
            print_usage(argv[0]);
            return 1;
        }

        std::string service = argv[2];

        // Validate command
        if (command != "start" && command != "stop" && 
            command != "restart" && command != "status") {
            std::cerr << "Error: Unknown command '" << command << "'\n\n";
            print_usage(argv[0]);
            return 1;
        }

        // Send command to AirRide
        std::string full_command = command + " " + service;
        std::string response = send_command(full_command);

        if (!response.empty()) {
            std::cout << response;
            
            // Check if operation was successful
            if (response.find("FAILED") != std::string::npos) {
                return 1;
            }
            return 0;
        }

        return 1;
    }
};

int main(int argc, char* argv[]) {
    AirRideCtl ctl;
    return ctl.run(argc, argv);
}
