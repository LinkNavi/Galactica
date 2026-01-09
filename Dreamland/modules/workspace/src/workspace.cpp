/*
 * Dreamland Workspace Module v2.0
 * Enhanced containerized project management with config files
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>
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
#define MAGENTA "\033[0;35m"
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

// ============================================
// CONFIGURATION PARSER
// ============================================

class ConfigParser {
public:
    std::map<std::string, std::string> data;
    
    bool load(const std::string& path) {
        if (!fs::exists(path)) return false;
        std::ifstream f(path);
        std::string line;
        while (std::getline(f, line)) {
            // Skip comments and empty lines
            line = trim(line);
            if (line.empty() || line[0] == '#') continue;
            
            size_t eq = line.find(':');
            if (eq == std::string::npos) eq = line.find('=');
            if (eq == std::string::npos) continue;
            
            std::string key = trim(line.substr(0, eq));
            std::string val = trim(line.substr(eq + 1));
            
            // Remove quotes if present
            if (val.size() >= 2 && val[0] == '"' && val.back() == '"')
                val = val.substr(1, val.size() - 2);
            
            data[key] = val;
        }
        return true;
    }
    
    void save(const std::string& path) {
        fs::create_directories(fs::path(path).parent_path());
        std::ofstream f(path);
        for (auto& [k, v] : data) {
            f << k << ": " << v << "\n";
        }
    }
    
    std::string get(const std::string& key, const std::string& def = "") const {
        auto it = data.find(key);
        return it != data.end() ? it->second : def;
    }
    
    void set(const std::string& key, const std::string& val) {
        data[key] = val;
    }
    
    bool has(const std::string& key) const {
        return data.find(key) != data.end();
    }
    
    std::vector<std::string> get_list(const std::string& prefix) const {
        std::vector<std::string> result;
        for (auto& [k, v] : data) {
            if (k.find(prefix) == 0) result.push_back(v);
        }
        return result;
    }
    
private:
    static std::string trim(const std::string& s) {
        size_t start = 0, end = s.size();
        while (start < end && std::isspace(s[start])) start++;
        while (end > start && std::isspace(s[end - 1])) end--;
        return s.substr(start, end - start);
    }
};

// ============================================
// WORKSPACE STRUCTURE
// ============================================

struct Workspace {
    std::string name;
    std::string path;
    std::string lang;
    std::string display_name;
    std::string description;
    bool isolated = false;
    
    // Build configuration
    std::string build_cmd;
    std::string clean_cmd;
    std::string run_cmd;
    std::string test_cmd;
    
    // Environment
    std::map<std::string, std::string> env_vars;
    std::vector<std::string> mounts;
    std::vector<std::string> init_cmds;
    
    // Metadata
    std::string created;
    std::string author;
    std::vector<std::string> tags;
    
    ConfigParser config;
    
    bool load_config() {
        std::string cfg_path = path + "/.ws/config";
        if (!config.load(cfg_path)) return false;
        
        // Load all fields from config
        display_name = config.get("display_name", name);
        description = config.get("description");
        lang = config.get("lang", "generic");
        isolated = config.get("isolated") == "true";
        
        build_cmd = config.get("build_cmd");
        clean_cmd = config.get("clean_cmd");
        run_cmd = config.get("run_cmd");
        test_cmd = config.get("test_cmd");
        
        created = config.get("created");
        author = config.get("author");
        
        // Load environment variables
        for (auto& [k, v] : config.data) {
            if (k.find("env.") == 0) {
                env_vars[k.substr(4)] = v;
            }
        }
        
        // Load lists
        mounts = config.get_list("mount.");
        init_cmds = config.get_list("init.");
        tags = config.get_list("tag.");
        
        return true;
    }
    
    void save_config() {
        config.set("name", name);
        config.set("display_name", display_name);
        config.set("description", description);
        config.set("lang", lang);
        config.set("isolated", isolated ? "true" : "false");
        
        if (!build_cmd.empty()) config.set("build_cmd", build_cmd);
        if (!clean_cmd.empty()) config.set("clean_cmd", clean_cmd);
        if (!run_cmd.empty()) config.set("run_cmd", run_cmd);
        if (!test_cmd.empty()) config.set("test_cmd", test_cmd);
        
        if (!created.empty()) config.set("created", created);
        if (!author.empty()) config.set("author", author);
        
        // Save environment variables
        int env_idx = 0;
        for (auto& [k, v] : env_vars) {
            config.set("env." + k, v);
        }
        
        // Save lists
        for (size_t i = 0; i < mounts.size(); i++)
            config.set("mount." + std::to_string(i), mounts[i]);
        for (size_t i = 0; i < init_cmds.size(); i++)
            config.set("init." + std::to_string(i), init_cmds[i]);
        for (size_t i = 0; i < tags.size(); i++)
            config.set("tag." + std::to_string(i), tags[i]);
        
        fs::create_directories(path + "/.ws");
        config.save(path + "/.ws/config");
    }
};

// ============================================
// WORKSPACE MANAGEMENT
// ============================================

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
    }
    if (!cur.name.empty()) ws.push_back(cur);
    
    // Load detailed config for each workspace
    for (auto& w : ws) {
        w.load_config();
    }
    
    return ws;
}

static void save_workspaces(const std::vector<Workspace>& ws) {
    fs::create_directories(fs::path(ws_config()).parent_path());
    std::ofstream f(ws_config());
    for (auto& w : ws) {
        f << "[" << w.name << "]\n";
        f << "path=" << w.path << "\n\n";
    }
}

static Workspace* find_ws(std::vector<Workspace>& ws, const std::string& name) {
    for (auto& w : ws) if (w.name == name) return &w;
    return nullptr;
}

static void status(const std::string& m) { std::cout << BLUE << "[★] " << RESET << m << "\n"; }
static void ok(const std::string& m) { std::cout << GREEN << "[✓] " << RESET << m << "\n"; }
static void err(const std::string& m) { std::cerr << RED << "[✗] " << RESET << m << "\n"; }
static void info(const std::string& m) { std::cout << CYAN << "[i] " << RESET << m << "\n"; }

// ============================================
// LANGUAGE TEMPLATES
// ============================================

struct LangTemplate {
    std::string lang;
    std::string build_cmd;
    std::string clean_cmd;
    std::string run_cmd;
    std::string test_cmd;
    std::vector<std::string> files;
};

static std::map<std::string, LangTemplate> get_templates() {
    return {
        {"c", {
            "c",
            "make",
            "make clean",
            "./build/main",
            "",
            {"Makefile:CC=gcc\nCFLAGS=-Wall -Wextra -O2\n\nall:\n\t$(CC) $(CFLAGS) src/*.c -o build/main\n\nclean:\n\trm -rf build/*\n"}
        }},
        {"cpp", {
            "cpp",
            "make",
            "make clean",
            "./build/main",
            "",
            {"Makefile:CXX=g++\nCXXFLAGS=-Wall -Wextra -std=c++17 -O2\n\nall:\n\t$(CXX) $(CXXFLAGS) src/*.cpp -o build/main\n\nclean:\n\trm -rf build/*\n"}
        }},
        {"rust", {
            "rust",
            "cargo build --release",
            "cargo clean",
            "cargo run",
            "cargo test",
            {"Cargo.toml:[package]\nname = \"PROJECT\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
             "src/main.rs:fn main() {\n    println!(\"Hello from Dreamland!\");\n}\n"}
        }},
        {"python", {
            "python",
            "pip install -e .",
            "rm -rf build/ dist/ *.egg-info",
            "python src/main.py",
            "pytest tests/",
            {"requirements.txt:",
             "src/main.py:#!/usr/bin/env python3\n\nif __name__ == '__main__':\n    print('Hello from Dreamland!')\n"}
        }},
        {"go", {
            "go",
            "go build -o build/main ./src",
            "rm -rf build/",
            "./build/main",
            "go test ./...",
            {"go.mod:module PROJECT\n\ngo 1.21\n",
             "src/main.go:package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello from Dreamland!\")\n}\n"}
        }},
        {"node", {
            "node",
            "npm run build",
            "rm -rf dist/ node_modules/",
            "npm start",
            "npm test",
            {"package.json:{\n  \"name\": \"PROJECT\",\n  \"version\": \"1.0.0\",\n  \"scripts\": {\n    \"start\": \"node src/index.js\",\n    \"build\": \"echo 'Build complete'\"\n  }\n}\n",
             "src/index.js:console.log('Hello from Dreamland!');\n"}
        }}
    };
}

// ============================================
// COMMANDS
// ============================================

static int cmd_create(int argc, char** argv) {
    if (argc < 2) {
        std::cout << "Usage: ws-create <name> [options]\n\n";
        std::cout << "Options:\n";
        std::cout << "  --path <dir>         Custom path\n";
        std::cout << "  --lang <lang>        Language (c, cpp, rust, python, go, node)\n";
        std::cout << "  --isolated           Enable namespace isolation\n";
        std::cout << "  --description <text> Workspace description\n";
        std::cout << "  --author <name>      Author name\n";
        std::cout << "  --build <cmd>        Custom build command\n";
        std::cout << "  --run <cmd>          Custom run command\n";
        std::cout << "  --env KEY=VALUE      Set environment variable\n";
        return 1;
    }
    
    std::string name = argv[1];
    std::string path = ws_base() + "/" + name;
    std::string lang = "generic";
    std::string desc, author, build_cmd, run_cmd;
    bool isolated = false;
    std::map<std::string, std::string> env_vars;
    
    for (int i = 2; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--path" && i + 1 < argc) path = argv[++i];
        else if (arg == "--lang" && i + 1 < argc) lang = argv[++i];
        else if (arg == "--isolated") isolated = true;
        else if (arg == "--description" && i + 1 < argc) desc = argv[++i];
        else if (arg == "--author" && i + 1 < argc) author = argv[++i];
        else if (arg == "--build" && i + 1 < argc) build_cmd = argv[++i];
        else if (arg == "--run" && i + 1 < argc) run_cmd = argv[++i];
        else if (arg == "--env" && i + 1 < argc) {
            std::string env = argv[++i];
            size_t eq = env.find('=');
            if (eq != std::string::npos) {
                env_vars[env.substr(0, eq)] = env.substr(eq + 1);
            }
        }
    }
    
    auto ws = load_workspaces();
    if (find_ws(ws, name)) { err("Workspace '" + name + "' already exists"); return 1; }
    
    status("Creating workspace: " + name);
    
    // Create directory structure
    fs::create_directories(path);
    fs::create_directories(path + "/src");
    fs::create_directories(path + "/build");
    fs::create_directories(path + "/tests");
    fs::create_directories(path + "/.ws");
    
    // Apply language template
    auto templates = get_templates();
    if (templates.count(lang)) {
        auto& tpl = templates[lang];
        for (auto& f : tpl.files) {
            size_t colon = f.find(':');
            std::string fname = f.substr(0, colon);
            std::string content = f.substr(colon + 1);
            
            // Replace PROJECT placeholder
            size_t pos = 0;
            while ((pos = content.find("PROJECT", pos)) != std::string::npos) {
                content.replace(pos, 7, name);
                pos += name.length();
            }
            
            std::ofstream out(path + "/" + fname);
            out << content;
        }
        
        if (build_cmd.empty()) build_cmd = tpl.build_cmd;
        if (run_cmd.empty()) run_cmd = tpl.run_cmd;
    }
    
    // Create workspace object
    Workspace w;
    w.name = name;
    w.path = path;
    w.lang = lang;
    w.display_name = name;
    w.description = desc;
    w.author = author.empty() ? getenv("USER") : author;
    w.isolated = isolated;
    w.build_cmd = build_cmd;
    w.run_cmd = run_cmd;
    w.env_vars = env_vars;
    w.created = std::to_string(time(nullptr));
    
    // Apply template commands if available
    if (templates.count(lang)) {
        auto& tpl = templates[lang];
        if (w.build_cmd.empty()) w.build_cmd = tpl.build_cmd;
        w.clean_cmd = tpl.clean_cmd;
        if (w.run_cmd.empty()) w.run_cmd = tpl.run_cmd;
        w.test_cmd = tpl.test_cmd;
    }
    
    // Save config
    w.save_config();
    
    // Save to workspace list
    ws.push_back(w);
    save_workspaces(ws);
    
    ok("Workspace created: " + path);
    info("Language: " + lang);
    if (isolated) info("Isolation: enabled");
    if (!build_cmd.empty()) info("Build: " + build_cmd);
    std::cout << "\n" << CYAN << "Enter with: ws-enter " << name << RESET << "\n";
    
    return 0;
}

static int cmd_list(int, char**) {
    auto ws = load_workspaces();
    std::cout << PINK << "Workspaces (" << ws.size() << "):\n" << RESET;
    
    if (ws.empty()) {
        std::cout << "  None. Create with: " << CYAN << "ws-create <name>" << RESET << "\n";
        return 0;
    }
    
    for (auto& w : ws) {
        std::cout << "\n  " << PINK << "● " << w.display_name << RESET;
        if (w.isolated) std::cout << " " << YELLOW << "[isolated]" << RESET;
        std::cout << "\n";
        
        if (!w.description.empty())
            std::cout << "    " << w.description << "\n";
        std::cout << "    " << CYAN << w.lang << RESET << " • " << w.path << "\n";
        
        if (!w.tags.empty()) {
            std::cout << "    Tags: ";
            for (auto& t : w.tags) std::cout << MAGENTA << "#" << t << " " << RESET;
            std::cout << "\n";
        }
    }
    
    return 0;
}

static int cmd_enter(int argc, char** argv) {
    if (argc < 2) { std::cout << "Usage: ws-enter <name>\n"; return 1; }
    
    std::string name = argv[1];
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Workspace not found: " + name); return 1; }
    
    if (!fs::exists(w->path)) { err("Path missing: " + w->path); return 1; }
    
    status("Entering workspace: " + w->display_name);
    
    if (w->isolated) {
        status("Setting up isolation...");
        
        pid_t pid = fork();
        if (pid == 0) {
            if (unshare(CLONE_NEWNS) == -1) {
                std::cerr << YELLOW << "[!] Isolation requires privileges, entering normally\n" << RESET;
            } else {
                mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
                mount("tmpfs", "/tmp", "tmpfs", 0, "size=256M");
            }
            
            chdir(w->path.c_str());
            
            // Set environment variables
            setenv("WS_NAME", w->name.c_str(), 1);
            setenv("WS_PATH", w->path.c_str(), 1);
            setenv("WS_LANG", w->lang.c_str(), 1);
            setenv("WS_ISOLATED", "1", 1);
            
            for (auto& [k, v] : w->env_vars) {
                setenv(k.c_str(), v.c_str(), 1);
            }
            
            // Custom prompt
            std::string prompt = "(" + w->display_name + ") \\W $ ";
            setenv("PS1", prompt.c_str(), 1);
            
            // Run init commands
            for (auto& cmd : w->init_cmds) {
                system(cmd.c_str());
            }
            
            const char* shell = getenv("SHELL");
            if (!shell) shell = "/bin/sh";
            
            ok("Workspace ready. Type 'exit' to leave.");
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
        chdir(w->path.c_str());
        
        setenv("WS_NAME", w->name.c_str(), 1);
        setenv("WS_PATH", w->path.c_str(), 1);
        setenv("WS_LANG", w->lang.c_str(), 1);
        
        for (auto& [k, v] : w->env_vars) {
            setenv(k.c_str(), v.c_str(), 1);
        }
        
        std::string prompt = "(" + w->display_name + ") \\W $ ";
        setenv("PS1", prompt.c_str(), 1);
        
        for (auto& cmd : w->init_cmds) {
            system(cmd.c_str());
        }
        
        const char* shell = getenv("SHELL");
        if (!shell) shell = "/bin/sh";
        
        ok("Entered workspace. Type 'exit' to leave.");
        execlp(shell, shell, nullptr);
    }
    
    return 0;
}

static int cmd_delete(int argc, char** argv) {
    if (argc < 2) { std::cout << "Usage: ws-delete <name> [--force]\n"; return 1; }
    
    std::string name = argv[1];
    bool force = argc > 2 && std::string(argv[2]) == "--force";
    
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Not found: " + name); return 1; }
    
    if (!force) {
        std::cout << "Delete workspace '" << w->display_name << "' and all files? [y/N]: ";
        std::string ans; std::getline(std::cin, ans);
        if (ans != "y" && ans != "Y") { std::cout << "Cancelled\n"; return 0; }
    }
    
    status("Deleting: " + w->display_name);
    if (fs::exists(w->path)) fs::remove_all(w->path);
    
    ws.erase(std::remove_if(ws.begin(), ws.end(), [&](auto& x) { return x.name == name; }), ws.end());
    save_workspaces(ws);
    
    ok("Deleted: " + name);
    return 0;
}

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
    
    status("Building: " + w->display_name);
    chdir(w->path.c_str());
    
    if (!w->build_cmd.empty()) {
        info("Running: " + w->build_cmd);
        return system(w->build_cmd.c_str());
    }
    
    // Auto-detect build system
    if (fs::exists("Makefile")) return system("make");
    else if (fs::exists("CMakeLists.txt")) {
        fs::create_directories("build");
        return system("cd build && cmake .. && make");
    } else if (fs::exists("Cargo.toml")) return system("cargo build");
    else if (fs::exists("package.json")) return system("npm run build");
    else if (fs::exists("setup.py")) return system("pip install -e .");
    else {
        err("No build command configured and no build system detected");
        info("Set build command: ws-config " + name + " build_cmd \"your command\"");
        return 1;
    }
}

static int cmd_run(int argc, char** argv) {
    std::string name;
    if (argc >= 2) name = argv[1];
    else {
        const char* env = getenv("WS_NAME");
        if (env) name = env;
    }
    
    if (name.empty()) { err("No workspace active"); return 1; }
    
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Not found: " + name); return 1; }
    
    if (w->run_cmd.empty()) {
        err("No run command configured");
        info("Set run command: ws-config " + name + " run_cmd \"your command\"");
        return 1;
    }
    
    status("Running: " + w->display_name);
    chdir(w->path.c_str());
    return system(w->run_cmd.c_str());
}

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
    
    std::cout << PINK << "╭─ " << w->display_name << RESET << "\n";
    std::cout << "│\n";
    
    if (!w->description.empty())
        std::cout << "│ " << w->description << "\n│\n";
    
    std::cout << "│ Path:     " << w->path << "\n";
    std::cout << "│ Language: " << w->lang << "\n";
    std::cout << "│ Author:   " << w->author << "\n";
    std::cout << "│ Isolated: " << (w->isolated ? "yes" : "no") << "\n";
    
    if (!w->build_cmd.empty()) std::cout << "│ Build:    " << w->build_cmd << "\n";
    if (!w->run_cmd.empty()) std::cout << "│ Run:      " << w->run_cmd << "\n";
    if (!w->test_cmd.empty()) std::cout << "│ Test:     " << w->test_cmd << "\n";
    
    if (!w->env_vars.empty()) {
        std::cout << "│\n│ Environment:\n";
        for (auto& [k, v] : w->env_vars)
            std::cout << "│   " << CYAN << k << RESET << "=" << v << "\n";
    }
    
    if (fs::exists(w->path)) {
        size_t files = 0, size = 0;
        for (auto& e : fs::recursive_directory_iterator(w->path)) {
            if (e.is_regular_file()) { files++; size += e.file_size(); }
        }
        std::cout << "│\n";
        std::cout << "│ Files:    " << files << "\n";
        std::cout << "│ Size:     " << (size / 1024) << " KB\n";
    }
    
    std::cout << "╰─\n";
    return 0;
}

static int cmd_config(int argc, char** argv) {
    if (argc < 3) {
        std::cout << "Usage: ws-config <name> <key> [value]\n\n";
        std::cout << "Config keys:\n";
        std::cout << "  display_name       Display name\n";
        std::cout << "  description        Description\n";
        std::cout << "  build_cmd          Build command\n";
        std::cout << "  run_cmd            Run command\n";
        std::cout << "  test_cmd           Test command\n";
        std::cout << "  clean_cmd          Clean command\n";
        std::cout << "  env.KEY            Environment variable\n";
        std::cout << "  isolated           Enable/disable isolation (true/false)\n";
        return 1;
    }
    
    std::string name = argv[1];
    std::string key = argv[2];
    
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Not found: " + name); return 1; }
    
    if (argc == 3) {
        // Get value
        std::string val;
        if (key == "display_name") val = w->display_name;
        else if (key == "description") val = w->description;
        else if (key == "build_cmd") val = w->build_cmd;
        else if (key == "run_cmd") val = w->run_cmd;
        else if (key == "test_cmd") val = w->test_cmd;
        else if (key == "clean_cmd") val = w->clean_cmd;
        else if (key == "isolated") val = w->isolated ? "true" : "false";
        else if (key.find("env.") == 0) {
            std::string env_key = key.substr(4);
            if (w->env_vars.count(env_key)) val = w->env_vars[env_key];
            else { err("Environment variable not set: " + env_key); return 1; }
        }
        else { err("Unknown key: " + key); return 1; }
        
        std::cout << key << " = " << val << "\n";
        return 0;
    }
    
    // Set value
    std::string value = argv[3];
    
    if (key == "display_name") w->display_name = value;
    else if (key == "description") w->description = value;
    else if (key == "build_cmd") w->build_cmd = value;
    else if (key == "run_cmd") w->run_cmd = value;
    else if (key == "test_cmd") w->test_cmd = value;
    else if (key == "clean_cmd") w->clean_cmd = value;
    else if (key == "isolated") w->isolated = (value == "true" || value == "1");
    else if (key.find("env.") == 0) {
        std::string env_key = key.substr(4);
        w->env_vars[env_key] = value;
    }
    else { err("Unknown key: " + key); return 1; }
    
    w->save_config();
    save_workspaces(ws);
    ok("Updated " + key);
    
    return 0;
}

static int cmd_clean(int argc, char** argv) {
    std::string name;
    if (argc >= 2) name = argv[1];
    else {
        const char* env = getenv("WS_NAME");
        if (env) name = env;
    }
    
    if (name.empty()) { err("No workspace active"); return 1; }
    
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Not found: " + name); return 1; }
    
    status("Cleaning: " + w->display_name);
    chdir(w->path.c_str());
    
    if (!w->clean_cmd.empty()) {
        return system(w->clean_cmd.c_str());
    }
    
    // Default clean
    if (fs::exists("build")) {
        fs::remove_all("build");
        fs::create_directories("build");
        ok("Cleaned build directory");
        return 0;
    }
    
    err("No clean command configured");
    return 1;
}

static int cmd_test(int argc, char** argv) {
    std::string name;
    if (argc >= 2) name = argv[1];
    else {
        const char* env = getenv("WS_NAME");
        if (env) name = env;
    }
    
    if (name.empty()) { err("No workspace active"); return 1; }
    
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Not found: " + name); return 1; }
    
    if (w->test_cmd.empty()) {
        err("No test command configured");
        info("Set test command: ws-config " + name + " test_cmd \"your command\"");
        return 1;
    }
    
    status("Testing: " + w->display_name);
    chdir(w->path.c_str());
    return system(w->test_cmd.c_str());
}

static int cmd_clone(int argc, char** argv) {
    if (argc < 3) {
        std::cout << "Usage: ws-clone <source> <new_name>\n";
        return 1;
    }
    
    std::string src_name = argv[1];
    std::string dst_name = argv[2];
    
    auto ws = load_workspaces();
    Workspace* src = find_ws(ws, src_name);
    if (!src) { err("Source not found: " + src_name); return 1; }
    if (find_ws(ws, dst_name)) { err("Destination exists: " + dst_name); return 1; }
    
    status("Cloning workspace: " + src_name + " → " + dst_name);
    
    std::string dst_path = ws_base() + "/" + dst_name;
    
    // Copy directory
    fs::copy(src->path, dst_path, fs::copy_options::recursive);
    
    // Create new workspace
    Workspace w = *src;
    w.name = dst_name;
    w.path = dst_path;
    w.display_name = dst_name;
    w.created = std::to_string(time(nullptr));
    
    w.save_config();
    ws.push_back(w);
    save_workspaces(ws);
    
    ok("Cloned to: " + dst_path);
    return 0;
}

static int cmd_export(int argc, char** argv) {
    if (argc < 3) {
        std::cout << "Usage: ws-export <name> <output.tar.gz>\n";
        return 1;
    }
    
    std::string name = argv[1];
    std::string output = argv[2];
    
    auto ws = load_workspaces();
    Workspace* w = find_ws(ws, name);
    if (!w) { err("Not found: " + name); return 1; }
    
    status("Exporting workspace: " + name);
    
    std::string cmd = "tar czf " + output + " -C " + 
                      fs::path(w->path).parent_path().string() + " " +
                      fs::path(w->path).filename().string();
    
    int ret = system(cmd.c_str());
    if (ret == 0) ok("Exported to: " + output);
    else err("Export failed");
    
    return ret;
}

static int cmd_import(int argc, char** argv) {
    if (argc < 3) {
        std::cout << "Usage: ws-import <archive.tar.gz> <name>\n";
        return 1;
    }
    
    std::string archive = argv[1];
    std::string name = argv[2];
    
    if (!fs::exists(archive)) { err("Archive not found: " + archive); return 1; }
    
    auto ws = load_workspaces();
    if (find_ws(ws, name)) { err("Workspace exists: " + name); return 1; }
    
    status("Importing workspace: " + name);
    
    std::string dst_path = ws_base() + "/" + name;
    fs::create_directories(dst_path);
    
    std::string cmd = "tar xzf " + archive + " -C " + dst_path + " --strip-components=1";
    int ret = system(cmd.c_str());
    
    if (ret != 0) {
        err("Import failed");
        fs::remove_all(dst_path);
        return ret;
    }
    
    // Load workspace config
    Workspace w;
    w.name = name;
    w.path = dst_path;
    w.load_config();
    
    ws.push_back(w);
    save_workspaces(ws);
    
    ok("Imported: " + name);
    return 0;
}

// ============================================
// MODULE EXPORTS
// ============================================

#include "dreamland_module.h"

static DreamlandModuleInfo module_info = {
    DREAMLAND_MODULE_API_VERSION,
    "workspace",
    "2.0.0",
    "Enhanced containerized project workspace manager with config files",
    "Galactica"
};

static DreamlandCommand commands[] = {
    {"ws-create", "Create a new workspace", "ws-create <name> [--lang <lang>] [--isolated]", cmd_create},
    {"ws-list", "List all workspaces", "ws-list", cmd_list},
    {"ws-enter", "Enter a workspace", "ws-enter <name>", cmd_enter},
    {"ws-delete", "Delete a workspace", "ws-delete <name> [--force]", cmd_delete},
    {"ws-build", "Build workspace project", "ws-build [name]", cmd_build},
    {"ws-run", "Run workspace project", "ws-run [name]", cmd_run},
    {"ws-test", "Test workspace project", "ws-test [name]", cmd_test},
    {"ws-clean", "Clean workspace build", "ws-clean [name]", cmd_clean},
    {"ws-status", "Show workspace status", "ws-status [name]", cmd_status},
    {"ws-config", "Get/set workspace config", "ws-config <name> <key> [value]", cmd_config},
    {"ws-clone", "Clone a workspace", "ws-clone <source> <new_name>", cmd_clone},
    {"ws-export", "Export workspace to archive", "ws-export <name> <output.tar.gz>", cmd_export},
    {"ws-import", "Import workspace from archive", "ws-import <archive.tar.gz> <name>", cmd_import},
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
