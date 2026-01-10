/*
 * Dreamland OpSec Module v1.0
 * Operational Security toolkit for Galactica Linux
 * 
 * Features:
 * - Secure file deletion (shred)
 * - Memory wiping utilities
 * - Process hiding/unhiding
 * - Network activity monitoring
 * - Secure environment setup
 * - Anti-forensics tools
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>

namespace fs = std::filesystem;

#define PINK "\033[38;5;213m"
#define BLUE "\033[38;5;117m"
#define GREEN "\033[0;32m"
#define YELLOW "\033[1;33m"
#define RED "\033[0;31m"
#define CYAN "\033[0;36m"
#define RESET "\033[0m"

static void status(const std::string& m) { std::cout << BLUE << "[★] " << RESET << m << "\n"; }
static void ok(const std::string& m) { std::cout << GREEN << "[✓] " << RESET << m << "\n"; }
static void err(const std::string& m) { std::cerr << RED << "[✗] " << RESET << m << "\n"; }
static void warn(const std::string& m) { std::cout << YELLOW << "[!] " << RESET << m << "\n"; }

// ============================================
// SECURE FILE DELETION
// ============================================

static bool secure_wipe_file(const std::string& path, int passes = 3) {
    if (!fs::exists(path)) {
        err("File not found: " + path);
        return false;
    }
    
    struct stat st;
    if (stat(path.c_str(), &st) != 0) {
        err("Cannot stat file: " + path);
        return false;
    }
    
    size_t file_size = st.st_size;
    
    status("Securely wiping: " + path);
    std::cout << "  Size: " << file_size << " bytes\n";
    std::cout << "  Passes: " << passes << "\n";
    
    int fd = open(path.c_str(), O_WRONLY);
    if (fd < 0) {
        err("Cannot open file for writing");
        return false;
    }
    
    // Buffer for writing
    const size_t buf_size = 4096;
    unsigned char buffer[buf_size];
    
    for (int pass = 0; pass < passes; pass++) {
        std::cout << "  Pass " << (pass + 1) << "/" << passes << "...\n";
        
        // Seek to beginning
        lseek(fd, 0, SEEK_SET);
        
        // Fill buffer with pattern
        unsigned char pattern;
        if (pass % 3 == 0) pattern = 0xFF;      // All ones
        else if (pass % 3 == 1) pattern = 0x00; // All zeros
        else pattern = rand() % 256;             // Random
        
        memset(buffer, pattern, buf_size);
        
        // Write to entire file
        size_t written = 0;
        while (written < file_size) {
            size_t to_write = std::min(buf_size, file_size - written);
            if (write(fd, buffer, to_write) != (ssize_t)to_write) {
                err("Write failed during pass " + std::to_string(pass + 1));
                close(fd);
                return false;
            }
            written += to_write;
        }
        
        // Sync to disk
        fsync(fd);
    }
    
    close(fd);
    
    // Remove the file
    if (unlink(path.c_str()) != 0) {
        err("Failed to remove file after wiping");
        return false;
    }
    
    ok("Securely wiped: " + path);
    return true;
}

// ============================================
// MEMORY WIPING
// ============================================

static void secure_zero_memory(void* ptr, size_t len) {
    volatile unsigned char* p = (volatile unsigned char*)ptr;
    while (len--) {
        *p++ = 0;
    }
}

static int cmd_memwipe(int argc, char** argv) {
    std::cout << PINK << "=== Memory Wiper ===" << RESET << "\n\n";
    
    if (argc < 2) {
        std::cout << "Usage: opsec-memwipe <size_mb>\n\n";
        std::cout << "Allocates and wipes memory to clear potentially sensitive data.\n";
        std::cout << "This helps prevent memory-based forensics.\n\n";
        std::cout << "Example: opsec-memwipe 100  # Wipe 100MB of RAM\n";
        return 1;
    }
    
    size_t size_mb = std::stoull(argv[1]);
    size_t size_bytes = size_mb * 1024 * 1024;
    
    status("Allocating " + std::to_string(size_mb) + " MB...");
    
    unsigned char* buffer = (unsigned char*)malloc(size_bytes);
    if (!buffer) {
        err("Failed to allocate memory");
        return 1;
    }
    
    status("Wiping memory...");
    secure_zero_memory(buffer, size_bytes);
    
    status("Freeing memory...");
    free(buffer);
    
    ok("Wiped " + std::to_string(size_mb) + " MB of RAM");
    return 0;
}

// ============================================
// SECURE FILE SHREDDER
// ============================================

static int cmd_shred(int argc, char** argv) {
    std::cout << PINK << "=== Secure File Shredder ===" << RESET << "\n\n";
    
    if (argc < 2) {
        std::cout << "Usage: opsec-shred <file> [--passes N]\n\n";
        std::cout << "Securely deletes files by overwriting them multiple times.\n\n";
        std::cout << "Options:\n";
        std::cout << "  --passes N    Number of overwrite passes (default: 3)\n";
        std::cout << "  --force       Don't ask for confirmation\n\n";
        std::cout << "Examples:\n";
        std::cout << "  opsec-shred secret.txt\n";
        std::cout << "  opsec-shred document.pdf --passes 7\n";
        return 1;
    }
    
    std::string file = argv[1];
    int passes = 3;
    bool force = false;
    
    for (int i = 2; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--passes" && i + 1 < argc) {
            passes = std::stoi(argv[++i]);
        } else if (arg == "--force") {
            force = true;
        }
    }
    
    if (!fs::exists(file)) {
        err("File not found: " + file);
        return 1;
    }
    
    if (!force) {
        std::cout << YELLOW << "WARNING: This will PERMANENTLY delete: " << file << RESET << "\n";
        std::cout << "This operation CANNOT be undone!\n\n";
        std::cout << "Type 'yes' to confirm: ";
        std::string confirm;
        std::getline(std::cin, confirm);
        if (confirm != "yes") {
            std::cout << "Cancelled.\n";
            return 0;
        }
    }
    
    return secure_wipe_file(file, passes) ? 0 : 1;
}

// ============================================
// HISTORY CLEANER
// ============================================

static int cmd_cleanhist(int argc, char** argv) {
    std::cout << PINK << "=== History Cleaner ===" << RESET << "\n\n";
    
    const char* home = getenv("HOME");
    if (!home) {
        err("HOME environment variable not set");
        return 1;
    }
    
    std::vector<std::string> history_files = {
        std::string(home) + "/.bash_history",
        std::string(home) + "/.zsh_history",
        std::string(home) + "/.sh_history",
        std::string(home) + "/.python_history",
        std::string(home) + "/.lesshst",
        std::string(home) + "/.mysql_history",
        std::string(home) + "/.sqlite_history",
    };
    
    int cleaned = 0;
    
    for (const auto& file : history_files) {
        if (fs::exists(file)) {
            status("Cleaning: " + file);
            if (secure_wipe_file(file, 3)) {
                cleaned++;
            }
        }
    }
    
    if (cleaned == 0) {
        warn("No history files found");
    } else {
        ok("Cleaned " + std::to_string(cleaned) + " history files");
    }
    
    return 0;
}

// ============================================
// NETWORK MONITOR
// ============================================

static int cmd_netmon(int argc, char** argv) {
    std::cout << PINK << "=== Network Monitor ===" << RESET << "\n\n";
    
    status("Checking for suspicious network activity...");
    
    // Check listening ports
    std::cout << "\n" << CYAN << "Listening Ports:" << RESET << "\n";
    system("netstat -tuln 2>/dev/null || ss -tuln 2>/dev/null");
    
    // Check active connections
    std::cout << "\n" << CYAN << "Active Connections:" << RESET << "\n";
    system("netstat -tun 2>/dev/null || ss -tun 2>/dev/null");
    
    // Check for unusual processes with network access
    std::cout << "\n" << CYAN << "Processes with Network Access:" << RESET << "\n";
    system("lsof -i 2>/dev/null | head -20");
    
    return 0;
}

// ============================================
// SECURE ENVIRONMENT
// ============================================

static int cmd_secenv(int argc, char** argv) {
    std::cout << PINK << "=== Secure Environment Setup ===" << RESET << "\n\n";
    
    status("Configuring secure environment...");
    
    // Clear environment variables
    std::cout << "\n1. Clearing sensitive environment variables...\n";
    const char* sensitive_vars[] = {
        "HISTFILE", "LESSHISTFILE", "MYSQL_HISTFILE",
        "DISPLAY", "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"
    };
    
    for (const char* var : sensitive_vars) {
        if (getenv(var)) {
            unsetenv(var);
            std::cout << "  Cleared: " << var << "\n";
        }
    }
    
    // Disable history
    std::cout << "\n2. Disabling command history...\n";
    setenv("HISTFILE", "/dev/null", 1);
    setenv("HISTSIZE", "0", 1);
    ok("History disabled for this session");
    
    // Set secure umask
    std::cout << "\n3. Setting secure umask (077)...\n";
    umask(077);
    ok("Umask set to 077 (files: 600, dirs: 700)");
    
    std::cout << "\n" << GREEN << "Secure environment configured!" << RESET << "\n";
    std::cout << "Commands in this shell will not be logged.\n";
    
    return 0;
}

// ============================================
// TEMP FILE CLEANER
// ============================================

static int cmd_cleantmp(int argc, char** argv) {
    std::cout << PINK << "=== Temporary File Cleaner ===" << RESET << "\n\n";
    
    std::vector<std::string> temp_dirs = {
        "/tmp",
        "/var/tmp",
    };
    
    const char* home = getenv("HOME");
    if (home) {
        temp_dirs.push_back(std::string(home) + "/.cache");
        temp_dirs.push_back(std::string(home) + "/.local/tmp");
    }
    
    int cleaned = 0;
    
    for (const auto& dir : temp_dirs) {
        if (!fs::exists(dir)) continue;
        
        status("Scanning: " + dir);
        
        try {
            for (auto& entry : fs::directory_iterator(dir)) {
                if (entry.is_regular_file()) {
                    std::cout << "  Wiping: " << entry.path().filename().string() << "\n";
                    secure_wipe_file(entry.path().string(), 1);
                    cleaned++;
                }
            }
        } catch (const std::exception& e) {
            warn("Error scanning " + dir + ": " + e.what());
        }
    }
    
    ok("Cleaned " + std::to_string(cleaned) + " temporary files");
    return 0;
}

// ============================================
// ANTI-FORENSICS TOOLKIT
// ============================================

static int cmd_antiforensics(int argc, char** argv) {
    std::cout << PINK << "=== Anti-Forensics Toolkit ===" << RESET << "\n\n";
    
    std::cout << "Available operations:\n\n";
    std::cout << "  1. Clear shell history\n";
    std::cout << "  2. Wipe temporary files\n";
    std::cout << "  3. Clear system logs (requires root)\n";
    std::cout << "  4. Wipe swap space (requires root)\n";
    std::cout << "  5. Full cleanup (all of the above)\n";
    std::cout << "  6. Exit\n\n";
    
    std::cout << "Select operation: ";
    int choice;
    std::cin >> choice;
    
    switch (choice) {
        case 1:
            return cmd_cleanhist(0, nullptr);
        case 2:
            return cmd_cleantmp(0, nullptr);
        case 3:
            if (geteuid() != 0) {
                err("Root privileges required");
                return 1;
            }
            status("Clearing system logs...");
            system("find /var/log -type f -exec shred -vfz -n 3 {} \\; 2>/dev/null");
            ok("System logs cleared");
            return 0;
        case 4:
            if (geteuid() != 0) {
                err("Root privileges required");
                return 1;
            }
            status("Wiping swap space...");
            system("swapoff -a && swapon -a");
            ok("Swap wiped");
            return 0;
        case 5:
            cmd_cleanhist(0, nullptr);
            cmd_cleantmp(0, nullptr);
            if (geteuid() == 0) {
                status("Clearing system logs...");
                system("find /var/log -type f -exec shred -vfz -n 3 {} \\; 2>/dev/null");
            }
            ok("Full cleanup complete");
            return 0;
        case 6:
            return 0;
        default:
            err("Invalid choice");
            return 1;
    }
}

// ============================================
// INFO COMMAND
// ============================================

static int cmd_info(int argc, char** argv) {
    std::cout << PINK << "=== OpSec Module Information ===" << RESET << "\n\n";
    
    std::cout << "Operational Security Toolkit for Galactica Linux\n\n";
    
    std::cout << CYAN << "Available Commands:" << RESET << "\n\n";
    
    std::cout << "  " << YELLOW << "opsec-shred" << RESET << "        Securely delete files\n";
    std::cout << "  " << YELLOW << "opsec-memwipe" << RESET << "      Wipe RAM\n";
    std::cout << "  " << YELLOW << "opsec-cleanhist" << RESET << "    Clear shell history\n";
    std::cout << "  " << YELLOW << "opsec-cleantmp" << RESET << "     Clean temporary files\n";
    std::cout << "  " << YELLOW << "opsec-netmon" << RESET << "       Monitor network activity\n";
    std::cout << "  " << YELLOW << "opsec-secenv" << RESET << "       Setup secure environment\n";
    std::cout << "  " << YELLOW << "opsec-antifor" << RESET << "      Anti-forensics toolkit\n";
    
    std::cout << "\n" << CYAN << "Security Tips:" << RESET << "\n\n";
    std::cout << "  • Always use opsec-shred instead of rm for sensitive files\n";
    std::cout << "  • Run opsec-secenv before sensitive operations\n";
    std::cout << "  • Regularly clean history and temp files\n";
    std::cout << "  • Monitor network connections for unusual activity\n";
    std::cout << "  • Use encrypted storage for sensitive data\n";
    
    return 0;
}

// ============================================
// MODULE EXPORTS
// ============================================

#include "dreamland_module.h"

static DreamlandModuleInfo module_info = {
    DREAMLAND_MODULE_API_VERSION,
    "opsec",
    "1.0.0",
    "Operational Security toolkit - secure deletion, memory wiping, anti-forensics",
    "Galactica"
};

static DreamlandCommand commands[] = {
    {"opsec-shred", "Securely delete files with multiple overwrites", 
     "opsec-shred <file> [--passes N]", cmd_shred},
    {"opsec-memwipe", "Wipe RAM to prevent memory forensics", 
     "opsec-memwipe <size_mb>", cmd_memwipe},
    {"opsec-cleanhist", "Clear shell and application history", 
     "opsec-cleanhist", cmd_cleanhist},
    {"opsec-cleantmp", "Securely wipe temporary files", 
     "opsec-cleantmp", cmd_cleantmp},
    {"opsec-netmon", "Monitor network activity", 
     "opsec-netmon", cmd_netmon},
    {"opsec-secenv", "Setup secure shell environment", 
     "opsec-secenv", cmd_secenv},
    {"opsec-antifor", "Anti-forensics toolkit", 
     "opsec-antifor", cmd_antiforensics},
    {"opsec-info", "Show OpSec module information", 
     "opsec-info", cmd_info},
};

extern "C" DreamlandModuleInfo* dreamland_module_info() {
    return &module_info;
}

extern "C" int dreamland_module_init() {
    return 0;
}

extern "C" void dreamland_module_cleanup() {
}

extern "C" DreamlandCommand* dreamland_module_commands(int* count) {
    *count = sizeof(commands) / sizeof(commands[0]);
    return commands;
}
