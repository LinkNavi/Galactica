#include <algorithm>
#include <archive.h>
#include <archive_entry.h>
#include <cstdlib>
#include <cstring>
#include <curl/curl.h>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <queue>
#include <set>
#include <sstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
#include "../include/dreamland_module.h"

namespace fs = std::filesystem;

#define PINK "\033[38;5;213m"
#define BLUE "\033[38;5;117m"
#define GREEN "\033[0;32m"
#define YELLOW "\033[1;33m"
#define RED "\033[0;31m"
#define CYAN "\033[0;36m"
#define RESET "\033[0m"

#define GALACTICA_REPO "LinkNavi/GalacticaRepository"
#define GALACTICA_RAW_URL "https://raw.githubusercontent.com/" GALACTICA_REPO "/main/"

const std::vector<std::string> ARCH_MIRRORS = {
    "https://mirror.rackspace.com/archlinux",
    "https://mirrors.kernel.org/archlinux",
    "https://geo.mirror.pkgbuild.com"
};
const std::vector<std::string> ARCH_REPOS = {"core", "extra"};

enum class PackageSource { GALACTICA, ARCH_BINARY, MODULE, UNKNOWN };

struct Package {
    std::string name, version, description, url, category, repo, filename, build_script;
    std::vector<std::string> dependencies;
    std::map<std::string, std::string> build_flags;
    bool installed = false, deps_resolved = false;
    PackageSource source = PackageSource::UNKNOWN;
    size_t size = 0;
};

struct LoadedModule {
    void* handle;
    DreamlandModuleInfo* info;
    std::vector<DreamlandCommand> commands;
    dreamland_module_cleanup_fn cleanup;
};

static size_t write_cb(void* c, size_t s, size_t n, std::string* o) { o->append((char*)c, s*n); return s*n; }
static size_t write_file_cb(void* c, size_t s, size_t n, FILE* f) { return fwrite(c, s, n, f); }

class Dreamland {
    std::string cache_dir, pkg_db, build_dir, installed_db, pkg_index, pkg_cache_dir, db_cache_dir, manifest_dir, modules_dir;
    bool debug = false;
    std::map<std::string, Package> packages, installed;
    std::set<std::string> galactica_pkgs;
    std::map<std::string, LoadedModule> modules;

    std::string home() { const char* h = getenv("HOME"); return h ? h : "/tmp"; }

    void init() {
        std::string h = home();
        const char* xc = getenv("XDG_CACHE_HOME");
        const char* xd = getenv("XDG_DATA_HOME");
        std::string bc = xc ? xc : h + "/.cache";
        std::string bd = xd ? xd : h + "/.local/share";
        cache_dir = bc + "/dreamland";
        build_dir = cache_dir + "/build";
        pkg_index = cache_dir + "/package_index.txt";
        pkg_cache_dir = cache_dir + "/packages";
        db_cache_dir = cache_dir + "/db";
        installed_db = bd + "/dreamland/installed.db";
        pkg_db = bd + "/dreamland/packages.db";
        manifest_dir = bd + "/dreamland/manifests";
        modules_dir = bd + "/dreamland/modules";
        debug = getenv("DREAMLAND_DEBUG") && std::string(getenv("DREAMLAND_DEBUG")) == "1";
        fs::create_directories(cache_dir); fs::create_directories(build_dir);
        fs::create_directories(pkg_cache_dir); fs::create_directories(db_cache_dir);
        fs::create_directories(fs::path(installed_db).parent_path());
        fs::create_directories(manifest_dir); fs::create_directories(modules_dir);
    }

    void banner() { std::cout << PINK << "    ★ DREAMLAND ★\n    Package Manager + Modules\n" << RESET << "\n"; }
    void status(const std::string& m) { std::cout << BLUE << "[★] " << RESET << m << "\n"; }
    void ok(const std::string& m) { std::cout << GREEN << "[✓] " << RESET << m << "\n"; }
    void err(const std::string& m) { std::cerr << RED << "[✗] " << RESET << m << "\n"; }
    void warn(const std::string& m) { std::cout << YELLOW << "[!] " << RESET << m << "\n"; }
    void dbg(const std::string& m) { if (debug) std::cout << "[D] " << m << "\n"; }

    bool dl_str(const std::string& url, std::string& out) {
        CURL* c = curl_easy_init(); if (!c) return false;
        curl_easy_setopt(c, CURLOPT_URL, url.c_str());
        curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_cb);
        curl_easy_setopt(c, CURLOPT_WRITEDATA, &out);
        curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(c, CURLOPT_TIMEOUT, 30L);
        CURLcode r = curl_easy_perform(c);
        long rc; curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &rc);
        curl_easy_cleanup(c);
        return r == CURLE_OK && rc == 200;
    }

    bool dl_file(const std::string& url, const std::string& path) {
        if (fs::exists(path) && fs::file_size(path) > 0) return true;
        CURL* c = curl_easy_init(); if (!c) return false;
        fs::create_directories(fs::path(path).parent_path());
        FILE* f = fopen(path.c_str(), "wb"); if (!f) { curl_easy_cleanup(c); return false; }
        curl_easy_setopt(c, CURLOPT_URL, url.c_str());
        curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_file_cb);
        curl_easy_setopt(c, CURLOPT_WRITEDATA, f);
        curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(c, CURLOPT_TIMEOUT, 300L);
        CURLcode r = curl_easy_perform(c);
        long rc; curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &rc);
        fclose(f); curl_easy_cleanup(c);
        if (r != CURLE_OK || rc != 200) { fs::remove(path); return false; }
        return fs::file_size(path) > 0;
    }

    int exec(const std::string& cmd) { return WEXITSTATUS(system(cmd.c_str())); }

    bool load_mod(const std::string& path) {
        dbg("Loading: " + path);
        void* h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!h) { err("dlopen: " + std::string(dlerror())); return false; }
        auto info_fn = (dreamland_module_info_fn)dlsym(h, "dreamland_module_info");
        if (!info_fn) { err("No info fn"); dlclose(h); return false; }
        DreamlandModuleInfo* info = info_fn();
        if (!info || info->api_version != DREAMLAND_MODULE_API_VERSION) {
            err("API mismatch"); dlclose(h); return false;
        }
        LoadedModule m; m.handle = h; m.info = info;
        m.cleanup = (dreamland_module_cleanup_fn)dlsym(h, "dreamland_module_cleanup");
        auto init_fn = (dreamland_module_init_fn)dlsym(h, "dreamland_module_init");
        if (init_fn && init_fn() != 0) { err("Init failed"); dlclose(h); return false; }
        auto cmd_fn = (dreamland_module_commands_fn)dlsym(h, "dreamland_module_commands");
        if (cmd_fn) {
            int cnt = 0; DreamlandCommand* cmds = cmd_fn(&cnt);
            for (int i = 0; i < cnt; i++) m.commands.push_back(cmds[i]);
        }
        modules[info->name] = m;
        dbg("Loaded: " + std::string(info->name));
        return true;
    }

    void load_all_mods() {
        if (!fs::exists(modules_dir)) return;
        for (auto& e : fs::directory_iterator(modules_dir))
            if (e.path().extension() == ".so") load_mod(e.path().string());
    }

    void unload_mods() {
        for (auto& [n, m] : modules) { if (m.cleanup) m.cleanup(); dlclose(m.handle); }
        modules.clear();
    }

    void save_pkg_db() {
        std::ofstream f(pkg_db); if (!f) return;
        for (auto& [n, p] : packages) {
            if (p.source != PackageSource::ARCH_BINARY) continue;
            f << "ARCH|" << p.name << "|" << p.version << "|" << p.repo << "|" << p.filename
              << "|" << p.size << "|" << p.description << "|" << (p.deps_resolved ? "1" : "0") << "\n";
        }
    }

    void load_pkg_db() {
        std::ifstream f(pkg_db); if (!f) return;
        std::string l;
        while (std::getline(f, l)) {
            std::istringstream is(l);
            std::string t, n, v, r, fn, sz, d, dr;
            std::getline(is, t, '|'); std::getline(is, n, '|'); std::getline(is, v, '|');
            std::getline(is, r, '|'); std::getline(is, fn, '|'); std::getline(is, sz, '|');
            std::getline(is, d, '|'); std::getline(is, dr, '|');
            if (t == "ARCH") {
                Package p; p.name = n; p.version = v; p.repo = r; p.filename = fn;
                try { p.size = std::stoull(sz); } catch (...) {}
                p.description = d; p.source = PackageSource::ARCH_BINARY;
                p.deps_resolved = dr == "1";
                packages[n] = p;
            }
        }
    }

    bool fetch_galactica() {
        status("Fetching Galactica index...");
        std::string content;
        if (!dl_str(GALACTICA_RAW_URL "INDEX", content)) { err("Failed"); return false; }
        std::ofstream(pkg_index) << content;
        galactica_pkgs.clear();
        std::istringstream is(content); std::string l;
        while (std::getline(is, l)) {
            l.erase(0, l.find_first_not_of(" \t\r\n"));
            l.erase(l.find_last_not_of(" \t\r\n") + 1);
            if (!l.empty() && l[0] != '#') galactica_pkgs.insert(l);
        }
        ok(std::to_string(galactica_pkgs.size()) + " Galactica packages");
        return true;
    }

    bool parse_arch_db(const std::string& db, const std::string& repo) {
        std::string dir = db_cache_dir + "/" + repo;
        fs::create_directories(dir);
        if (exec("tar -xzf " + db + " -C " + dir + " 2>/dev/null") != 0) return false;
        int cnt = 0;
        for (auto& e : fs::directory_iterator(dir)) {
            if (!e.is_directory()) continue;
            std::string desc = e.path().string() + "/desc";
            if (!fs::exists(desc)) continue;
            Package p; p.source = PackageSource::ARCH_BINARY; p.repo = repo;
            std::ifstream f(desc); std::string l, sec;
            while (std::getline(f, l)) {
                if (l.empty()) continue;
                if (l[0] == '%' && l.back() == '%') { sec = l.substr(1, l.size()-2); continue; }
                if (sec == "NAME") p.name = l;
                else if (sec == "VERSION") p.version = l;
                else if (sec == "DESC" && p.description.empty()) p.description = l;
                else if (sec == "FILENAME") p.filename = l;
                else if (sec == "CSIZE") try { p.size = std::stoull(l); } catch (...) {}
            }
            if (!p.name.empty() && packages.find(p.name) == packages.end()) { packages[p.name] = p; cnt++; }
        }
        ok(std::to_string(cnt) + " from " + repo);
        return cnt > 0;
    }

    bool sync_arch() {
        status("Syncing Arch databases...");
        for (auto& mirror : ARCH_MIRRORS) {
            bool good = true;
            for (auto& repo : ARCH_REPOS) {
                std::string url = mirror + "/" + repo + "/os/x86_64/" + repo + ".db";
                std::string file = db_cache_dir + "/" + repo + ".db";
                if (!dl_file(url, file) || !parse_arch_db(file, repo)) { good = false; break; }
            }
            if (good) return true;
        }
        return false;
    }

    bool extract_pkg(const std::string& pkg, const std::string& dest, std::vector<std::string>* files = nullptr) {
        struct archive *a = archive_read_new(), *ext = archive_write_disk_new();
        archive_read_support_filter_all(a); archive_read_support_format_all(a);
        archive_write_disk_set_options(ext, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM);
        if (archive_read_open_filename(a, pkg.c_str(), 10240) != ARCHIVE_OK) {
            archive_read_free(a); archive_write_free(ext); return false;
        }
        struct archive_entry* entry;
        while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
            std::string pn = archive_entry_pathname(entry);
            if (pn[0] == '.' && (pn.find(".PKGINFO") != std::string::npos || pn.find(".MTREE") != std::string::npos)) continue;
            std::string fp = dest + "/" + pn;
            archive_entry_set_pathname(entry, fp.c_str());
            if (archive_write_header(ext, entry) == ARCHIVE_OK) {
                if (files && archive_entry_filetype(entry) == AE_IFREG) files->push_back("/" + pn);
                const void* buf; size_t sz; int64_t off;
                while (archive_read_data_block(a, &buf, &sz, &off) == ARCHIVE_OK)
                    archive_write_data_block(ext, buf, sz, off);
            }
        }
        archive_read_close(a); archive_read_free(a);
        archive_write_close(ext); archive_write_free(ext);
        return true;
    }

    void save_installed() {
        std::ofstream f(installed_db); if (!f) return;
        for (auto& [n, p] : installed) {
            std::string src = p.source == PackageSource::MODULE ? "module" :
                              p.source == PackageSource::GALACTICA ? "galactica" : "arch";
            f << n << " " << p.version << " " << src << "\n";
        }
    }

    void load_installed() {
        std::ifstream f(installed_db); if (!f) return;
        std::string l;
        while (std::getline(f, l)) {
            if (l.empty()) continue;
            std::istringstream is(l);
            Package p; std::string src;
            is >> p.name >> p.version >> src;
            p.installed = true;
            p.source = src == "module" ? PackageSource::MODULE :
                       src == "galactica" ? PackageSource::GALACTICA : PackageSource::ARCH_BINARY;
            installed[p.name] = p;
        }
    }

    bool install_arch(const Package& p) {
        std::cout << "Installing: " << PINK << p.name << RESET << " " << p.version << "\n";
        std::string cached = pkg_cache_dir + "/" + p.filename;
        if (!fs::exists(cached)) {
            status("Downloading...");
            for (auto& m : ARCH_MIRRORS) {
                if (dl_file(m + "/" + p.repo + "/os/x86_64/" + p.filename, cached)) break;
            }
            if (!fs::exists(cached)) { err("Download failed"); return false; }
        }
        std::vector<std::string> files;
        if (!extract_pkg(cached, "", &files)) { err("Extract failed"); return false; }
        std::ofstream mf(manifest_dir + "/" + p.name + ".manifest");
        for (auto& f : files) mf << f << "\n";
        Package ip = p; ip.installed = true;
        installed[p.name] = ip;
        save_installed();
        ok("Installed " + p.name);
        return true;
    }

    bool install_mod(const std::string& name) {
        std::string url = GALACTICA_RAW_URL "modules/" + name + ".so";
        std::string path = modules_dir + "/" + name + ".so";
        status("Downloading module: " + name);
        if (!dl_file(url, path)) { err("Download failed"); return false; }
        if (!load_mod(path)) { fs::remove(path); return false; }
        Package p; p.name = name; p.version = modules[name].info->version;
        p.source = PackageSource::MODULE; p.installed = true;
        installed[name] = p;
        save_installed();
        ok("Module " + name + " ready");
        return true;
    }

    bool uninstall_pkg(const std::string& name) {
        load_installed();
        auto it = installed.find(name);
        if (it == installed.end()) { err("Not installed: " + name); return false; }
        Package& p = it->second;
        status("Uninstalling: " + name);
        if (p.source == PackageSource::MODULE) {
            auto mit = modules.find(name);
            if (mit != modules.end()) {
                if (mit->second.cleanup) mit->second.cleanup();
                dlclose(mit->second.handle);
                modules.erase(mit);
            }
            std::string mod_path = modules_dir + "/" + name + ".so";
            if (fs::exists(mod_path)) fs::remove(mod_path);
            ok("Module removed");
        } else {
            std::string mf = manifest_dir + "/" + name + ".manifest";
            if (fs::exists(mf)) {
                std::ifstream f(mf);
                std::string line;
                std::vector<std::string> files;
                while (std::getline(f, line)) if (!line.empty()) files.push_back(line);
                f.close();
                std::sort(files.rbegin(), files.rend());
                int removed = 0;
                for (auto& file : files) {
                    try { if (fs::exists(file)) { fs::remove(file); removed++; } } catch (...) {}
                }
                fs::remove(mf);
                ok("Removed " + std::to_string(removed) + " files");
            } else {
                warn("No manifest, removing from db only");
            }
        }
        installed.erase(name);
        save_installed();
        ok("Uninstalled: " + name);
        return true;
    }

public:
    Dreamland() { init(); curl_global_init(CURL_GLOBAL_DEFAULT); load_all_mods(); }
    ~Dreamland() { unload_mods(); curl_global_cleanup(); }

    void sync() {
        banner(); fetch_galactica(); sync_arch(); save_pkg_db(); load_installed();
        ok("Sync complete");
        std::cout << "  " << modules.size() << " modules loaded\n";
    }

    void search(const std::string& q) {
        if (packages.empty()) load_pkg_db();
        load_installed();
        for (auto& [n, p] : packages) {
            if (n.find(q) != std::string::npos || p.description.find(q) != std::string::npos) {
                std::cout << PINK << n << RESET << " " << p.version
                          << (installed.count(n) ? GREEN " [installed]" RESET : "") << "\n";
            }
        }
    }

    bool install(const std::string& name) {
        load_installed();
        if (packages.empty()) load_pkg_db();
        if (name.rfind("module-", 0) == 0) return install_mod(name.substr(7));
        if (installed.count(name)) { warn(name + " already installed"); return false; }
        auto it = packages.find(name);
        if (it == packages.end()) { err("Not found: " + name); return false; }
        return install_arch(it->second);
    }

    bool uninstall(const std::string& name) { return uninstall_pkg(name); }

    void list() {
        banner(); load_installed();
        if (installed.empty()) { warn("Nothing installed"); return; }
        for (auto& [n, p] : installed) {
            std::string t = p.source == PackageSource::MODULE ? PINK "[module]" RESET :
                            p.source == PackageSource::GALACTICA ? CYAN "[source]" RESET : YELLOW "[binary]" RESET;
            std::cout << "  " << n << " " << p.version << " " << t << "\n";
        }
    }

    void list_mods() {
        banner();
        std::cout << "Modules (" << modules.size() << "):\n\n";
        if (modules.empty()) { std::cout << "  None. Install: dreamland install module-<n>\n"; return; }
        for (auto& [n, m] : modules) {
            std::cout << PINK << "  " << m.info->name << RESET << " v" << m.info->version << "\n";
            std::cout << "    " << m.info->description << "\n";
            for (auto& c : m.commands)
                std::cout << "      " << CYAN << c.name << RESET << " - " << c.description << "\n";
            std::cout << "\n";
        }
    }

    bool has_cmd(const std::string& cmd) {
        for (auto& [n, m] : modules) for (auto& c : m.commands) if (cmd == c.name) return true;
        return false;
    }

    bool run_cmd(int argc, char** argv) {
        if (argc < 2) return false;
        std::string cmd = argv[1];
        for (auto& [n, m] : modules)
            for (auto& c : m.commands)
                if (cmd == c.name) return c.handler(argc - 1, argv + 1) == 0;
        return false;
    }

    void usage(const std::string& prog) {
        banner();
        std::cout << "Usage: " << prog << " <command> [args]\n\n";
        std::cout << "Core:\n";
        std::cout << "  sync            Sync databases\n";
        std::cout << "  install <pkg>   Install package or module-<n>\n";
        std::cout << "  uninstall <pkg> Uninstall package or module\n";
        std::cout << "  search <q>      Search packages\n";
        std::cout << "  list            List installed\n";
        std::cout << "  modules         List modules\n";
        if (!modules.empty()) {
            std::cout << "\nModule commands:\n";
            for (auto& [n, m] : modules)
                for (auto& c : m.commands)
                    std::cout << "  " << c.name << std::string(14 - strlen(c.name), ' ')
                              << c.description << " [" << m.info->name << "]\n";
        }
    }
};

int main(int argc, char* argv[]) {
    Dreamland dl;
    if (argc < 2) { dl.usage(argv[0]); return 1; }
    std::string cmd = argv[1];
    if (dl.has_cmd(cmd)) return dl.run_cmd(argc, argv) ? 0 : 1;
    if (cmd == "sync") dl.sync();
    else if (cmd == "search" && argc >= 3) dl.search(argv[2]);
    else if (cmd == "install" && argc >= 3) return dl.install(argv[2]) ? 0 : 1;
    else if (cmd == "uninstall" && argc >= 3) return dl.uninstall(argv[2]) ? 0 : 1;
    else if (cmd == "list") dl.list();
    else if (cmd == "modules") dl.list_mods();
    else { dl.usage(argv[0]); return 1; }
    return 0;
}
