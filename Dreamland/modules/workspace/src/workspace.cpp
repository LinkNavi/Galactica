/*
 * Dreamland Workspace Module
 * Containerized project management using Linux namespaces
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iostream>
#include <algorithm>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sched.h>
#include <fcntl.h>
#include <pwd.h>

namespace fs = std::filesystem;

#define PINK "\033[38;5;213m"
#define BLUE "\033[38;5;117m"
#define GREEN "\033[0;32m"
#define YELLOW "\033[1;33m"
#define RED "\033[0;31m"
#define CYAN "\033[0;36m"
#define RESET "\033[0m"

static std::string home_dir() {
    const char* h = getenv("HOME");
    return h ? h : "/tmp";
}

static std::string ws_base() {
    return home_dir() + "/.local/share/dreamland/workspaces";
}

static std::string ws_config() {
    return home_dir() + "/.config/dreamland/workspaces.conf";
}

struct Workspace {
    std::string name;
    std::string path;
    std::string lang;
    bool isolated = false;
    std::vector<std::string> mounts;
};

static std::vector<Workspace> load_workspaces() {
    std::vector<Workspace> ws;
    std::string cfg = ws_config();
    if (!fs::exists(cfg)) return ws;
    std::ifstream f(cfg);
    std::string line;
    Workspace cur;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        if (line[0] == '[' && line.back() == ']') {
            if (!cur.name.empty()) ws.push_back(cur);
            cur = Workspace();
            cur.name = line.substr(1, line.size() - 2);
            continue;
        }
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string k = line.substr(0, eq), v = line.substr(eq + 1);
        if (k == "path") cur.path = v;
        else if (k == "lang") cur.lang = v;
        else if (k == "isolated") cur.isolated = (v == "true" || v == "1");
        else if (k == "mount") cur.mounts.push_back(v);
    }
    if (!cur.name.empty()) ws.push_back(cur);
    return ws;
}

static void save_workspaces(const std::vector<Workspace>& ws) {
    fs::create_directories(fs::path(ws_config()).parent_path());
    std::ofstream f(ws_config());
    for (auto& w : ws) {
        f << "[" << w.name << "]\n";
        f << "path=" << w.path << "\n";
        f << "lang=" << w.lang << "\n";
        f << "isolated=" << (w.isolated ? "true" : "false") << "\n";
        for (auto& m : w.mounts) f << "mount=" << m << "\n";
        f << "\n";
    }
}

static Workspace* find_ws(std::vector<Workspace>& ws, const std::string& name) {
    for (auto& w : ws) if (w.name == name) return &w;
    return nullptr;
}

static void status(const std::string& m) { std::cout << BLUE << "[★] " << RESET << m << "\n"; }
static void ok(const std::string& m) { std::cout << GREEN << "[✓] " << RESET << m << "\n"; }
static void err(const std::string& m) { std::cerr << RED << "[✗] " << RESET << m << "\n"; }

// Create workspace
static int cmd_create(int argc, char** argv) {
    if (argc < 2) {
        std::cout << "Usage: ws-create <name> [--path <dir>] [--lang <lang>] [--isolated]\n";
        return 1;
    }
    
    std::string name = argv[1];
    std::string path = ws_base() + "/" + name;
    std::string lang = "generic";
    bool isolated = false;
    
    for (int i = 2; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--path" && i + 1 < argc) path = argv[++i];
        else if (arg == "--lang" && i + 1 < argc) lang = argv[++i];
        else if (arg == "--isolated") isolated = true;
    }
    
    auto ws = load_workspaces();
    if (find_ws(ws, name)) { err("Workspace '" + name + "' exists"); return 1; }
    
    status("Creating workspace: " + name);
    
    // Create directory structure
    fs::create_directories(path);
    fs::create_directories(path + "/src");
    fs::create_directories(path + "/build");
    fs::create_directories(path + "/.ws");
    
    // Create workspace metadata
    std::ofstream meta(path + "/.ws/meta");
    meta << "name=" << name << "\n";
    meta << "lang=" << lang << "\n";
    meta << "created=" << time(nullptr) << "\n";
    
    // Language-specific setup
    if (lang == "c" || lang == "cpp") {
        std::ofstream mk(path + "/Makefile");
        mk << "CC=gcc\nCXX=g++\nCFLAGS=-Wall -Wextra -O2\n\n";
        mk << "all:\n\t$(CC) $(CFLAGS) src/*.c -o build/main\n\n";
        mk << "clean:\n\trm -rf build/*\n";
    } else if (lang == "python") {
        fs::create_directories(path + "/venv");
        std::ofstream req(path + "/requirements.txt");
    } else if (lang == "rust") {
        std::ofstream cargo(path + "/Cargo.toml");
        cargo << "[package]\nname = \"" << name << "\"\nversion = \"0.1.0\"\nedition = \"2021\"\n";
    }
    
    // Save to config
    Workspace w;
    w.name = name; w.path = path; w.lang = lang; w.isolated = isolated;
    ws.push_back(w);
    save_workspaces(ws);
    
    ok("Workspace created: " + path);
    if (isolated) std::cout << "  " << CYAN << "Isolation enabled" << RESET << "\n";
    return 0;
}

// List workspaces
static int cmd_list(int, char**) {
    auto ws = load_workspaces();
    std::cout << PINK << "Workspaces (" << ws.size() << "):\n" << RESET;
    if (ws.empty()) {
        std::cout << "  None. Create with: " << CYAN << "ws-create <name>" << RESET << "\n";
        return 0;
    }
    for (auto& w : ws) {
        std::cout << "\n  " << PINK << w.name << RESET;
        if (w.isolated) std::cout << " " << YELLOW << "[isolated]" << RESET;
        std::cout << "\n";
        std::cout << "    Path: " << w.path << "\n";
        std::cout << "    Lang: " << w.lang << "\n";
    }
    return 0;
}

// Enter workspace (with optional isolation)
static int cmd_enter(int argc, char** argv) {
    if (argc < 2) { std::cout << "Usage: ws-enter <name>\n"; return 1; }
    
    std::string name = argv[1];
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Workspace not found: " + name); return 1; }
    
    if (!fs::exists(w->path)) { err("Path missing: " + w->path); return 1; }
    
    status("Entering workspace: " + name);
    
    if (w->isolated) {
        // Use unshare for lightweight isolation (mount namespace)
        status("Setting up isolation...");
        
        pid_t pid = fork();
        if (pid == 0) {
            // Child - set up isolated environment
            if (unshare(CLONE_NEWNS) == -1) {
                // Fallback if unprivileged
                std::cerr << YELLOW << "[!] Isolation requires privileges, entering normally\n" << RESET;
            } else {
                // Make mount namespace private
                mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
                
                // Mount tmpfs for /tmp
                mount("tmpfs", "/tmp", "tmpfs", 0, "size=256M");
            }
            
            chdir(w->path.c_str());
            setenv("WS_NAME", w->name.c_str(), 1);
            setenv("WS_PATH", w->path.c_str(), 1);
            setenv("WS_ISOLATED", "1", 1);
            setenv("PS1", ("(" + w->name + ") \\W $ ").c_str(), 1);
            
            const char* shell = getenv("SHELL");
            if (!shell) shell = "/bin/sh";
            
            ok("Isolated workspace ready. Type 'exit' to leave.");
            execlp(shell, shell, nullptr);
            _exit(127);
        } else if (pid > 0) {
            int status;
            waitpid(pid, &status, 0);
            ok("Left workspace: " + name);
            return WEXITSTATUS(status);
        } else {
            err("Fork failed");
            return 1;
        }
    } else {
        // Simple non-isolated entry
        chdir(w->path.c_str());
        setenv("WS_NAME", w->name.c_str(), 1);
        setenv("WS_PATH", w->path.c_str(), 1);
        setenv("PS1", ("(" + w->name + ") \\W $ ").c_str(), 1);
        
        const char* shell = getenv("SHELL");
        if (!shell) shell = "/bin/sh";
        
        ok("Entered workspace. Type 'exit' to leave.");
        execlp(shell, shell, nullptr);
    }
    
    return 0;
}

// Delete workspace
static int cmd_delete(int argc, char** argv) {
    if (argc < 2) { std::cout << "Usage: ws-delete <name> [--force]\n"; return 1; }
    
    std::string name = argv[1];
    bool force = argc > 2 && std::string(argv[2]) == "--force";
    
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Not found: " + name); return 1; }
    
    if (!force) {
        std::cout << "Delete workspace '" << name << "' and all files? [y/N]: ";
        std::string ans; std::getline(std::cin, ans);
        if (ans != "y" && ans != "Y") { std::cout << "Cancelled\n"; return 0; }
    }
    
    status("Deleting: " + name);
    if (fs::exists(w->path)) fs::remove_all(w->path);
    
    ws.erase(std::remove_if(ws.begin(), ws.end(), [&](auto& x) { return x.name == name; }), ws.end());
    save_workspaces(ws);
    
    ok("Deleted: " + name);
    return 0;
}

// Build workspace project
static int cmd_build(int argc, char** argv) {
    std::string name;
    if (argc >= 2) name = argv[1];
    else {
        const char* env = getenv("WS_NAME");
        if (env) name = env;
    }
    
    if (name.empty()) { err("No workspace. Use ws-build <name> or enter one first."); return 1; }
    
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Not found: " + name); return 1; }
    
    status("Building: " + name);
    chdir(w->path.c_str());
    
    // Detect build system
    if (fs::exists("Makefile")) {
        return system("make");
    } else if (fs::exists("CMakeLists.txt")) {
        fs::create_directories("build");
        return system("cd build && cmake .. && make");
    } else if (fs::exists("Cargo.toml")) {
        return system("cargo build");
    } else if (fs::exists("package.json")) {
        return system("npm run build");
    } else if (fs::exists("setup.py") || fs::exists("pyproject.toml")) {
        return system("pip install -e .");
    } else {
        err("No build system detected");
        return 1;
    }
}

// Status of workspace
static int cmd_status(int argc, char** argv) {
    std::string name;
    if (argc >= 2) name = argv[1];
    else {
        const char* env = getenv("WS_NAME");
        if (env) name = env;
    }
    
    if (name.empty()) { cmd_list(0, nullptr); return 0; }
    
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Not found: " + name); return 1; }
    
    std::cout << PINK << "Workspace: " << w->name << RESET << "\n\n";
    std::cout << "  Path:     " << w->path << "\n";
    std::cout << "  Language: " << w->lang << "\n";
    std::cout << "  Isolated: " << (w->isolated ? "yes" : "no") << "\n";
    
    if (fs::exists(w->path)) {
        size_t files = 0, size = 0;
        for (auto& e : fs::recursive_directory_iterator(w->path)) {
            if (e.is_regular_file()) { files++; size += e.file_size(); }
        }
        std::cout << "  Files:    " << files << "\n";
        std::cout << "  Size:     " << (size / 1024) << " KB\n";
    }
    
    return 0;
}

// ============================================
// MODULE EXPORTS
// ============================================

#include "dreamland_module.h"

static DreamlandModuleInfo module_info = {
    DREAMLAND_MODULE_API_VERSION,
    "workspace",
    "1.0.0",
    "Containerized project workspace manager",
    "Galactica"
};

static DreamlandCommand commands[] = {
    {"ws-create", "Create a new workspace", "ws-create <name> [--isolated]", cmd_create},
    {"ws-list", "List all workspaces", "ws-list", cmd_list},
    {"ws-enter", "Enter a workspace", "ws-enter <name>", cmd_enter},
    {"ws-delete", "Delete a workspace", "ws-delete <name>", cmd_delete},
    {"ws-build", "Build workspace project", "ws-build [name]", cmd_build},
    {"ws-status", "Show workspace status", "ws-status [name]", cmd_status},
};

DREAMLAND_MODULE_EXPORT DreamlandModuleInfo* dreamland_module_info() {
    return &module_info;
}

DREAMLAND_MODULE_EXPORT int dreamland_module_init() {
    fs::create_directories(ws_base());
    return 0;
}

DREAMLAND_MODULE_EXPORT void dreamland_module_cleanup() {
    // Nothing to cleanup
}

DREAMLAND_MODULE_EXPORT DreamlandCommand* dreamland_module_commands(int* count) {
    *count = sizeof(commands) / sizeof(commands[0]);
    return commands;
}
