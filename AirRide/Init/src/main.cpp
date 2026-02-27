#include "airride.h"
#include <iostream>
#include <csignal>
#include <unistd.h>

// mount_filesystems(), set_hostname(), and clear_console()
// are defined in mount.cpp — do not redefine here.

AirRide::AirRide() {}

void AirRide::run() {
    mount_filesystems();
    load_services();
    setup_control_socket();
    start_autostart_services();

    while (running) {
        reap_zombies();
        handle_control_commands();
    }
}

int main(int argc, char* argv[]) {
    (void)argc;
    (void)argv;

    // PID 1 must not exit, so catch everything we can
    signal(SIGTERM, SIG_IGN);
    signal(SIGHUP,  SIG_IGN);

    AirRide airride;
    airride.run();

    // Should never reach here as PID 1
    std::cerr << "[AirRide] run() returned — this should never happen" << std::endl;
    return 1;
}
