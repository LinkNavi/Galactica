#ifdef __linux__
#include "airride.h"
#include <cstring>
#include <fstream>
#include <iostream>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <fcntl.h>

void AirRide::mount_filesystems() {
    std::cout << "[AirRide] Mounting filesystems..." << std::endl;

    mkdir("/proc",        0755);
    mkdir("/sys",         0755);
    mkdir("/dev",         0755);
    mkdir("/run",         0755);
    mkdir("/tmp",         0755);
    mkdir("/dev/pts",     0755);
    mkdir("/dev/dri",     0755);
    mkdir("/var/log",     0755);
    mkdir(LOG_DIR,        0755);
    mkdir("/usr/share/udhcpc", 0755);

    mount("proc",     "/proc", "proc",     MS_NOEXEC | MS_NOSUID | MS_NODEV, nullptr);
    mount("sysfs",    "/sys",  "sysfs",    MS_NOEXEC | MS_NOSUID | MS_NODEV, nullptr);
    mount("devtmpfs", "/dev",  "devtmpfs", MS_NOSUID, "mode=0755");
    mount("devpts",   "/dev/pts", "devpts", 0, "gid=5,mode=620");
    mount("tmpfs",    "/run",  "tmpfs",    MS_NOEXEC | MS_NOSUID | MS_NODEV, "mode=0755");
    mount("tmpfs",    "/tmp",  "tmpfs",    MS_NOEXEC | MS_NOSUID | MS_NODEV, "mode=1777");

    mknod("/dev/console",  S_IFCHR | 0600, makedev(5,   1));
    mknod("/dev/null",     S_IFCHR | 0666, makedev(1,   3));
    mknod("/dev/zero",     S_IFCHR | 0666, makedev(1,   5));
    mknod("/dev/random",   S_IFCHR | 0666, makedev(1,   8));
    mknod("/dev/urandom",  S_IFCHR | 0666, makedev(1,   9));
    mknod("/dev/tty",      S_IFCHR | 0666, makedev(5,   0));
    mknod("/dev/tty0",     S_IFCHR | 0620, makedev(4,   0));
    mknod("/dev/tty1",     S_IFCHR | 0620, makedev(4,   1));
    mknod("/dev/tty2",     S_IFCHR | 0620, makedev(4,   2));
    mknod("/dev/tty3",     S_IFCHR | 0620, makedev(4,   3));
    mknod("/dev/ttyS0",    S_IFCHR | 0660, makedev(4,  64));
    mknod("/dev/fb0",      S_IFCHR | 0666, makedev(29,  0));
    mknod("/dev/dri/card0",      S_IFCHR | 0666, makedev(226,   0));
    mknod("/dev/dri/renderD128", S_IFCHR | 0666, makedev(226, 128));

    set_hostname();
    std::cout << "[AirRide] Filesystems ready" << std::endl;
}

void AirRide::set_hostname() {
    std::ifstream hf("/etc/hostname");
    std::string hostname = "galactica";
    if (hf.is_open()) { std::getline(hf, hostname); hf.close(); }
    if (!hostname.empty())
        if (sethostname(hostname.c_str(), hostname.length()) != 0)
            std::cerr << "[AirRide] Failed to set hostname" << std::endl;
}

void AirRide::clear_console() {
    int fd = open("/dev/console", O_WRONLY);
    if (fd >= 0) {
        const char *seq = "\033[2J\033[H";
        (void)write(fd, seq, strlen(seq));
        close(fd);
    }
    std::cout << "\033[2J\033[H" << std::flush;
}

#else
// Stubs for non-Linux builds
#include "airride.h"
#include <iostream>
void AirRide::mount_filesystems() {}
void AirRide::set_hostname() {}
void AirRide::clear_console() { std::cout << "\033[2J\033[H" << std::flush; }
#endif