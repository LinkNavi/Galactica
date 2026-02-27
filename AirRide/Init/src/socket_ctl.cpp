#ifdef __linux__
#include "airride.h"
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <sstream>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

void AirRide::setup_control_socket() {
    control_socket = socket(AF_UNIX, SOCK_STREAM, 0);
    if (control_socket == -1) return;

    unlink(AIRRIDE_SOCKET);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, AIRRIDE_SOCKET, sizeof(addr.sun_path) - 1);

    if (bind(control_socket, (struct sockaddr *)&addr, sizeof(addr)) == -1 ||
        listen(control_socket, 5) == -1) {
        close(control_socket);
        control_socket = -1;
        return;
    }

    epoll_fd = epoll_create1(0);
    if (epoll_fd == -1) {
        fcntl(control_socket, F_SETFL, fcntl(control_socket, F_GETFL, 0) | O_NONBLOCK);
        return;
    }

    struct epoll_event ev;
    ev.events  = EPOLLIN;
    ev.data.fd = control_socket;
    if (epoll_ctl(epoll_fd, EPOLL_CTL_ADD, control_socket, &ev) == -1) {
        close(epoll_fd);
        epoll_fd = -1;
        fcntl(control_socket, F_SETFL, fcntl(control_socket, F_GETFL, 0) | O_NONBLOCK);
    }
}

void AirRide::handle_control_commands() {
    if (control_socket == -1) return;

    if (epoll_fd != -1) {
        struct epoll_event events[4];
        int n = epoll_wait(epoll_fd, events, 4, 2000);
        if (n <= 0) return;
    }

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
        if      (cmd == "start")   response = start_service(svc_name)  ? "OK\n" : "FAILED\n";
        else if (cmd == "stop")    response = stop_service(svc_name)   ? "OK\n" : "FAILED\n";
        else if (cmd == "restart") { stop_service(svc_name); usleep(500000); response = start_service(svc_name) ? "OK\n" : "FAILED\n"; }
        else if (cmd == "status")  response = get_service_status(svc_name);
        else if (cmd == "list")    response = list_services();
        else                       response = "Unknown command\n";

        (void)write(client, response.c_str(), response.length());
    }
    close(client);
}

#else
#include "airride.h"
#include <iostream>
#include <unistd.h>
void AirRide::setup_control_socket() {}
void AirRide::handle_control_commands() { usleep(2000000); }
#endif