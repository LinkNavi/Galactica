#include "dreamland.h"
#include <dlfcn.h>
#include <iostream>

void Dreamland::load_all_mods() {
    for (auto& dir : module_search_paths) {
        if (!fs::exists(dir)) continue;
        for (auto& e : fs::directory_iterator(dir)) {
            if (e.path().extension() == ".so") {
                std::string name = e.path().stem().string();
                if (modules.count(name)) continue;
                load_mod(e.path().string());
            }
        }
    }
}

bool Dreamland::load_mod(const std::string& path) {
    dbg("Loading: " + path);
    void* h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h) { err("dlopen: " + std::string(dlerror())); return false; }

    auto info_fn = (dreamland_module_info_fn)dlsym(h, "dreamland_module_info");
    if (!info_fn) { err("No info fn in " + path); dlclose(h); return false; }

    DreamlandModuleInfo* info = info_fn();
    if (!info || info->api_version != DREAMLAND_MODULE_API_VERSION) {
        err("API version mismatch: " + path); dlclose(h); return false;
    }

    LoadedModule m;
    m.handle  = h;
    m.info    = info;
    m.cleanup = (dreamland_module_cleanup_fn)dlsym(h, "dreamland_module_cleanup");

    auto init_fn = (dreamland_module_init_fn)dlsym(h, "dreamland_module_init");
    if (init_fn && init_fn() != 0) { err("Init failed: " + path); dlclose(h); return false; }

    auto cmd_fn = (dreamland_module_commands_fn)dlsym(h, "dreamland_module_commands");
    if (cmd_fn) {
        int cnt = 0;
        DreamlandCommand* cmds = cmd_fn(&cnt);
        for (int i = 0; i < cnt; i++) m.commands.push_back(cmds[i]);
    }

    modules[info->name] = m;
    dbg("Loaded: " + std::string(info->name));
    return true;
}

void Dreamland::unload_mods() {
    for (auto& [n, m] : modules) {
        if (m.cleanup) m.cleanup();
        dlclose(m.handle);
    }
    modules.clear();
}

bool Dreamland::has_cmd(const std::string& cmd) {
    for (auto& [n, m] : modules)
        for (auto& c : m.commands)
            if (cmd == c.name) return true;
    return false;
}

bool Dreamland::run_cmd(int argc, char** argv) {
    if (argc < 2) return false;
    std::string cmd = argv[1];
    for (auto& [n, m] : modules)
        for (auto& c : m.commands)
            if (cmd == c.name) return c.handler(argc - 1, argv + 1) == 0;
    return false;
}
