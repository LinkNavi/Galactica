#include "../include/dreamland_module.h"
#include <algorithm>
#include <archive.h>
#include <archive_entry.h>
#include <chrono>
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
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

// ============================================================
// ANSI colors
// ============================================================
#define PINK    "\033[38;5;213m"
#define BLUE    "\033[38;5;117m"
#define GREEN   "\033[0;32m"
#define YELLOW  "\033[1;33m"
#define RED     "\033[0;31m"
#define CYAN    "\033[0;36m"
#define RESET   "\033[0m"

// ============================================================
// Constants
// ============================================================
#define DREAMLAND_VERSION "3.0.0"
#define GALACTICA_REPO    "LinkNavi/GalacticaRepository"
#define GALACTICA_RAW_URL "https://raw.githubusercontent.com/" GALACTICA_REPO "/main/"

const std::vector<std::string> ARCH_MIRRORS = {
    "https://mirror.rackspace.com/archlinux",
    "https://mirrors.kernel.org/archlinux",
    "https://geo.mirror.pkgbuild.com"
};
const std::vector<std::string> ARCH_REPOS = {"core", "extra"};

// ============================================================
// Package types
// ============================================================
enum class PackageSource { GALACTICA, ARCH_BINARY, MODULE, UNKNOWN };

struct Package {
    std::string name, version, description, url, category, repo, filename, build_script;
    std::vector<std::string> dependencies;
    std::vector<std::string> post_install;   // [PostInstall] section lines
    std::map<std::string, std::string> build_flags;
    bool installed     = false;
    bool deps_resolved = false;
    PackageSource source = PackageSource::UNKNOWN;
    size_t size = 0;
};

struct LoadedModule {
    void *handle = nullptr;
    DreamlandModuleInfo *info = nullptr;
    std::vector<DreamlandCommand> commands;
    dreamland_module_cleanup_fn cleanup = nullptr;
};

// ============================================================
// CURL helpers
// ============================================================
static size_t write_cb(void *c, size_t s, size_t n, std::string *o) {
    o->append((char *)c, s * n);
    return s * n;
}
static size_t write_file_cb(void *c, size_t s, size_t n, FILE *f) {
    return fwrite(c, s, n, f);
}

// Progress bar state for downloads
struct ProgressData {
    std::string name;
    bool shown = false;
};

static int progress_cb(void *clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t, curl_off_t) {
    auto *pd = static_cast<ProgressData *>(clientp);
    if (dltotal <= 0) return 0;
    int pct = (int)(100.0 * dlnow / dltotal);
    int bar = pct / 5; // 20-char bar
    std::cout << "\r  " << CYAN << pd->name << RESET << " ["
              << std::string(bar, '#') << std::string(20 - bar, ' ')
              << "] " << pct << "%   " << std::flush;
    pd->shown = true;
    return 0;
}

// ============================================================
// Dreamland
// ============================================================
class Dreamland {
    // Paths
    std::string cache_dir, pkg_db_path, build_dir, installed_db, pkg_index,
                pkg_cache_dir, db_cache_dir, manifest_dir, modules_dir;

    // State
    bool debug = false;
    std::map<std::string, Package> packages;
    std::map<std::string, Package> installed;
    std::set<std::string> galactica_pkgs;
    std::map<std::string, LoadedModule> modules;
    std::vector<std::string> module_search_paths;

    // --------------------------------------------------------
    // Init
    // --------------------------------------------------------
    std::string home_dir() {
        const char *h = getenv("HOME");
        return h ? h : "/tmp";
    }

    void init() {
        const char *xc = getenv("XDG_CACHE_HOME");
        const char *xd = getenv("XDG_DATA_HOME");
        std::string bc = xc ? xc : home_dir() + "/.cache";
        std::string bd = xd ? xd : home_dir() + "/.local/share";

        cache_dir    = bc + "/dreamland";
        build_dir    = cache_dir + "/build";
        pkg_index    = cache_dir + "/package_index.txt";
        pkg_cache_dir = cache_dir + "/packages";
        db_cache_dir = cache_dir + "/db";

        installed_db = bd + "/dreamland/installed.db";
        pkg_db_path  = bd + "/dreamland/packages.db";
        manifest_dir = bd + "/dreamland/manifests";

        module_search_paths = {
            "/usr/local/share/dreamland/modules",
            bd + "/dreamland/modules"
        };

        for (auto &p : module_search_paths) {
            if (fs::exists(p) && access(p.c_str(), W_OK) == 0) {
                modules_dir = p;
                break;
            }
        }
        if (modules_dir.empty()) modules_dir = module_search_paths.back();

        debug = (getenv("DREAMLAND_DEBUG") &&
                 std::string(getenv("DREAMLAND_DEBUG")) == "1");

        for (auto &d : {cache_dir, build_dir, pkg_cache_dir, db_cache_dir,
                        manifest_dir, fs::path(installed_db).parent_path().string()}) {
            fs::create_directories(d);
        }
        try { fs::create_directories(modules_dir); } catch (...) {}
    }

    // --------------------------------------------------------
    // Logging
    // --------------------------------------------------------
    void banner() {
        std::cout << PINK << "    ★ DREAMLAND ★\n    User's Choice  v" DREAMLAND_VERSION "\n" << RESET << "\n";
    }
    void status(const std::string &m) { std::cout << BLUE  << "[★] " << RESET << m << "\n"; }
    void ok    (const std::string &m) { std::cout << GREEN << "[✓] " << RESET << m << "\n"; }
    void err   (const std::string &m) { std::cerr << RED   << "[✗] " << RESET << m << "\n"; }
    void warn  (const std::string &m) { std::cout << YELLOW<< "[!] " << RESET << m << "\n"; }
    void dbg   (const std::string &m) { if (debug) std::cout << "[D] " << m << "\n"; }

    // --------------------------------------------------------
    // Network
    // --------------------------------------------------------
    bool dl_str(const std::string &url, std::string &out) {
        CURL *c = curl_easy_init();
        if (!c) return false;
        curl_easy_setopt(c, CURLOPT_URL,           url.c_str());
        curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_cb);
        curl_easy_setopt(c, CURLOPT_WRITEDATA,     &out);
        curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION,1L);
        curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER,0L);
        curl_easy_setopt(c, CURLOPT_TIMEOUT,       30L);
        CURLcode r = curl_easy_perform(c);
        long rc = 0;
        curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &rc);
        curl_easy_cleanup(c);
        return r == CURLE_OK && rc == 200;
    }

    bool dl_file(const std::string &url, const std::string &path, bool show_progress = false) {
        if (fs::exists(path) && fs::file_size(path) > 0) {
            dbg("Cached: " + path);
            return true;
        }
        CURL *c = curl_easy_init();
        if (!c) return false;

        try { fs::create_directories(fs::path(path).parent_path()); }
        catch (...) { curl_easy_cleanup(c); return false; }

        FILE *f = fopen(path.c_str(), "wb");
        if (!f) { curl_easy_cleanup(c); return false; }

        ProgressData pd;
        pd.name = fs::path(path).filename().string();

        curl_easy_setopt(c, CURLOPT_URL,            url.c_str());
        curl_easy_setopt(c, CURLOPT_WRITEFUNCTION,  write_file_cb);
        curl_easy_setopt(c, CURLOPT_WRITEDATA,      f);
        curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(c, CURLOPT_TIMEOUT,        300L);
        curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 30L);
        curl_easy_setopt(c, CURLOPT_FAILONERROR,    1L);

        if (show_progress) {
            curl_easy_setopt(c, CURLOPT_NOPROGRESS,          0L);
            curl_easy_setopt(c, CURLOPT_XFERINFOFUNCTION,    progress_cb);
            curl_easy_setopt(c, CURLOPT_XFERINFODATA,        &pd);
        }

        CURLcode r = curl_easy_perform(c);
        long rc = 0;
        curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &rc);
        fclose(f);
        curl_easy_cleanup(c);

        if (pd.shown) std::cout << "\n";

        if (r != CURLE_OK || rc != 200) {
            fs::remove(path);
            return false;
        }
        if (!fs::exists(path) || fs::file_size(path) == 0) {
            fs::remove(path);
            return false;
        }
        return true;
    }

    // --------------------------------------------------------
    // Shell execution — uses execve, avoids raw system() for
    // scripts that we construct ourselves.
    // For build scripts we still need a shell interpreter.
    // --------------------------------------------------------
    int exec_shell(const std::string &cmd) {
        pid_t pid = fork();
        if (pid == 0) {
            execl("/bin/sh", "sh", "-c", cmd.c_str(), nullptr);
            _exit(127);
        }
        if (pid < 0) return -1;
        int status = 0;
        waitpid(pid, &status, 0);
        return WEXITSTATUS(status);
    }

    // Run a build script file safely
    int run_script(const std::string &script_path) {
        pid_t pid = fork();
        if (pid == 0) {
            execl("/bin/sh", "sh", script_path.c_str(), nullptr);
            _exit(127);
        }
        if (pid < 0) return -1;
        int status = 0;
        waitpid(pid, &status, 0);
        return WEXITSTATUS(status);
    }

    // --------------------------------------------------------
    // Package database — persistence
    // --------------------------------------------------------
    void save_pkg_db() {
        std::ofstream f(pkg_db_path);
        if (!f) return;
        for (auto &[n, p] : packages) {
            if (p.source == PackageSource::ARCH_BINARY) {
                std::string deps;
                for (size_t i = 0; i < p.dependencies.size(); i++) {
                    if (i) deps += " ";
                    deps += p.dependencies[i];
                }
                f << "ARCH|" << p.name << "|" << p.version << "|" << p.repo
                  << "|" << p.filename << "|" << p.size << "|" << p.description
                  << "|" << deps << "\n";
            } else if (p.source == PackageSource::GALACTICA) {
                f << "GALACTICA|" << p.name << "|" << p.version << "|" << p.url
                  << "|" << p.category << "|" << p.description << "\n";
            }
        }
    }

    void load_pkg_db() {
        std::ifstream f(pkg_db_path);
        if (!f) return;
        std::string l;
        while (std::getline(f, l)) {
            if (l.empty()) continue;
            std::istringstream is(l);
            std::string type;
            std::getline(is, type, '|');

            if (type == "ARCH") {
                std::string n, v, r, fn, sz, d, deps_str;
                std::getline(is, n,    '|');
                std::getline(is, v,    '|');
                std::getline(is, r,    '|');
                std::getline(is, fn,   '|');
                std::getline(is, sz,   '|');
                std::getline(is, d,    '|');
                std::getline(is, deps_str);   // rest of line

                Package p;
                p.name = n; p.version = v; p.repo = r; p.filename = fn;
                try { p.size = std::stoull(sz); } catch (...) {}
                p.description = d;
                p.source = PackageSource::ARCH_BINARY;
                p.deps_resolved = !deps_str.empty();

                std::istringstream ds(deps_str);
                std::string dep;
                while (ds >> dep) p.dependencies.push_back(dep);
                packages[n] = p;

            } else if (type == "GALACTICA") {
                std::string n, v, u, c, d;
                std::getline(is, n, '|');
                std::getline(is, v, '|');
                std::getline(is, u, '|');
                std::getline(is, c, '|');
                std::getline(is, d);

                Package p;
                p.name = n; p.version = v; p.url = u;
                p.category = c; p.description = d;
                p.source = PackageSource::GALACTICA;
                packages[n] = p;
            }
        }
    }

    void save_installed() {
        std::ofstream f(installed_db);
        if (!f) return;
        for (auto &[n, p] : installed) {
            std::string src = p.source == PackageSource::MODULE      ? "module"
                            : p.source == PackageSource::GALACTICA   ? "galactica"
                                                                      : "arch";
            f << n << " " << p.version << " " << src << "\n";
        }
    }

    void load_installed() {
        installed.clear();
        std::ifstream f(installed_db);
        if (!f) return;
        std::string l;
        while (std::getline(f, l)) {
            if (l.empty()) continue;
            std::istringstream is(l);
            Package p;
            std::string src;
            is >> p.name >> p.version >> src;
            p.installed = true;
            p.source = src == "module"    ? PackageSource::MODULE
                     : src == "galactica" ? PackageSource::GALACTICA
                                          : PackageSource::ARCH_BINARY;
            installed[p.name] = p;
        }
    }

    // --------------------------------------------------------
    // Arch database parsing
    // --------------------------------------------------------
    bool parse_arch_db(const std::string &db, const std::string &repo) {
        std::string dir = db_cache_dir + "/" + repo;
        std::error_code ec;
        if (fs::exists(dir)) fs::remove_all(dir, ec);
        fs::create_directories(dir);

        if (exec_shell("tar -xzf " + db + " -C " + dir + " 2>/dev/null") != 0) {
            err("Failed to extract " + repo + " database");
            return false;
        }

        int cnt = 0;
        for (auto &e : fs::directory_iterator(dir)) {
            if (!e.is_directory()) continue;

            std::string desc_path    = e.path().string() + "/desc";
            std::string depends_path = e.path().string() + "/depends";
            if (!fs::exists(desc_path)) continue;

            Package p;
            p.source = PackageSource::ARCH_BINARY;
            p.repo   = repo;

            // Parse desc
            std::ifstream df(desc_path);
            std::string line, sec;
            while (std::getline(df, line)) {
                if (line.empty()) continue;
                if (line.front() == '%' && line.back() == '%') {
                    sec = line.substr(1, line.size() - 2);
                    continue;
                }
                if      (sec == "NAME")     p.name        = line;
                else if (sec == "VERSION")  p.version     = line;
                else if (sec == "DESC" && p.description.empty())
                                            p.description = line;
                else if (sec == "FILENAME") p.filename    = line;
                else if (sec == "CSIZE")    try { p.size = std::stoull(line); } catch (...) {}
            }

            // Parse depends
            if (fs::exists(depends_path)) {
                std::ifstream depsf(depends_path);
                std::string dsec;
                while (std::getline(depsf, line)) {
                    if (line.empty()) continue;
                    if (line.front() == '%' && line.back() == '%') {
                        dsec = line.substr(1, line.size() - 2);
                        continue;
                    }
                    if (dsec == "DEPENDS") {
                        // strip version constraints
                        size_t pos = line.find_first_of(">=<");
                        if (pos != std::string::npos) line = line.substr(0, pos);
                        if (!line.empty()) p.dependencies.push_back(line);
                    }
                }
            }

            if (!p.name.empty() && packages.find(p.name) == packages.end()) {
                packages[p.name] = p;
                cnt++;
            }
        }

        ok(std::to_string(cnt) + " packages from " + repo);
        return cnt > 0;
    }

    bool sync_arch() {
        status("Syncing Arch databases...");
        for (auto &mirror : ARCH_MIRRORS) {
            bool ok_all = true;
            for (auto &repo : ARCH_REPOS) {
                std::string url  = mirror + "/" + repo + "/os/x86_64/" + repo + ".db";
                std::string file = db_cache_dir + "/" + repo + ".db";
                // Always re-download db on sync
                fs::remove(file);
                if (!dl_file(url, file) || !parse_arch_db(file, repo)) {
                    ok_all = false;
                    break;
                }
            }
            if (ok_all) {
                ok("Synced from " + mirror);
                return true;
            }
            warn("Mirror failed, trying next...");
        }
        err("All mirrors failed");
        return false;
    }

    // --------------------------------------------------------
    // Galactica package parsing
    // --------------------------------------------------------
    bool parse_galactica_pkg(const std::string &pkg_path) {
        std::string content;
        if (!dl_str(GALACTICA_RAW_URL + pkg_path, content)) {
            dbg("Failed to fetch: " + pkg_path);
            return false;
        }

        Package p;
        p.source = PackageSource::GALACTICA;

        std::istringstream iss(content);
        std::string line, section;

        while (std::getline(iss, line)) {
            // trim
            auto ltrim = [](std::string &s) { s.erase(0, s.find_first_not_of(" \t\r\n")); };
            auto rtrim = [](std::string &s) {
                size_t e = s.find_last_not_of(" \t\r\n");
                if (e != std::string::npos) s.erase(e + 1);
                else s.clear();
            };
            ltrim(line); rtrim(line);
            if (line.empty() || line[0] == '#') continue;

            if (line[0] == '[' && line.back() == ']') {
                section = line.substr(1, line.size() - 2);
                continue;
            }

            // PostInstall section: accumulate raw lines
            if (section == "PostInstall") {
                p.post_install.push_back(line);
                continue;
            }

            // Script section: accumulate raw lines
            if (section == "Script") {
                if (!p.build_script.empty()) p.build_script += "\n";
                p.build_script += line;
                continue;
            }

            size_t eq = line.find('=');
            if (eq == std::string::npos) continue;
            std::string key = line.substr(0, eq);
            std::string val = line.substr(eq + 1);
            rtrim(key); ltrim(val);
            if (val.size() >= 2 && val.front() == '"' && val.back() == '"')
                val = val.substr(1, val.size() - 2);

            if (section == "Package") {
                if      (key == "name")        p.name        = val;
                else if (key == "version")     p.version     = val;
                else if (key == "description") p.description = val;
                else if (key == "url")         p.url         = val;
                else if (key == "category")    p.category    = val;
            } else if (section == "Dependencies") {
                if (key == "depends") {
                    std::istringstream ds(val);
                    std::string dep;
                    while (ds >> dep) p.dependencies.push_back(dep);
                }
            } else if (section == "Build") {
                p.build_flags[key] = val;
            }
        }

        if (!p.name.empty() && !p.version.empty()) {
            packages[p.name] = p;
            dbg("Loaded Galactica package: " + p.name);
            return true;
        }
        return false;
    }

    bool fetch_galactica() {
        status("Fetching Galactica index...");
        std::string content;
        if (!dl_str(GALACTICA_RAW_URL "INDEX", content)) {
            err("Failed to fetch Galactica INDEX");
            return false;
        }
        std::ofstream(pkg_index) << content;
        galactica_pkgs.clear();
        std::istringstream is(content);
        std::string l;
        while (std::getline(is, l)) {
            l.erase(0, l.find_first_not_of(" \t\r\n"));
            l.erase(l.find_last_not_of(" \t\r\n") + 1);
            if (!l.empty() && l[0] != '#') galactica_pkgs.insert(l);
        }
        ok(std::to_string(galactica_pkgs.size()) + " Galactica packages");
        return true;
    }

    bool load_galactica_packages() {
        int loaded = 0;
        for (auto &pp : galactica_pkgs)
            if (parse_galactica_pkg(pp)) loaded++;
        if (loaded) ok("Loaded " + std::to_string(loaded) + " Galactica packages");
        return loaded > 0;
    }

    // --------------------------------------------------------
    // Dependency resolution — purely database-driven, no downloads
    // --------------------------------------------------------
    std::string resolve_lib_to_pkg(const std::string &dep) {
        if (dep.find(".so") == std::string::npos) return dep;
        std::string base = dep.substr(0, dep.find(".so"));
        if (packages.count(base)) return base;
        if (base.size() > 3 && base.substr(0, 3) == "lib") {
            std::string without = base.substr(3);
            if (packages.count(without)) return without;
        }
        dbg("Could not resolve library: " + dep);
        return dep;
    }

    std::vector<std::string> resolve_dependencies(
        const std::string &pkg_name,
        std::set<std::string> &resolved,
        std::set<std::string> &visited)
    {
        std::vector<std::string> order;
        if (visited.count(pkg_name)) return order;
        visited.insert(pkg_name);
        if (installed.count(pkg_name)) { resolved.insert(pkg_name); return order; }

        auto it = packages.find(pkg_name);
        if (it == packages.end()) {
            warn("Dependency not found: " + pkg_name);
            return order;
        }

        for (auto &dep : it->second.dependencies) {
            std::string rd = resolve_lib_to_pkg(dep);
            if (!resolved.count(rd)) {
                auto sub = resolve_dependencies(rd, resolved, visited);
                order.insert(order.end(), sub.begin(), sub.end());
            }
        }

        if (!resolved.count(pkg_name)) {
            order.push_back(pkg_name);
            resolved.insert(pkg_name);
        }
        return order;
    }

    // --------------------------------------------------------
    // Archive extraction
    // --------------------------------------------------------
    bool extract_pkg(const std::string &pkg, const std::string &dest,
                     std::vector<std::string> *files = nullptr)
    {
        struct archive *a   = archive_read_new();
        struct archive *ext = archive_write_disk_new();
        archive_read_support_filter_all(a);
        archive_read_support_format_all(a);
        archive_write_disk_set_options(ext, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM);

        if (archive_read_open_filename(a, pkg.c_str(), 10240) != ARCHIVE_OK) {
            archive_read_free(a);
            archive_write_free(ext);
            return false;
        }

        struct archive_entry *entry;
        while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
            std::string pn = archive_entry_pathname(entry);
            // Skip metadata files
            if (pn.find(".PKGINFO") != std::string::npos ||
                pn.find(".MTREE")   != std::string::npos ||
                pn.find(".BUILDINFO") != std::string::npos) continue;

            std::string fp = dest.empty() ? ("/" + pn) : (dest + "/" + pn);
            archive_entry_set_pathname(entry, fp.c_str());

            if (archive_write_header(ext, entry) == ARCHIVE_OK) {
                if (files && archive_entry_filetype(entry) == AE_IFREG)
                    files->push_back("/" + pn);
                const void *buf; size_t sz; int64_t off;
                while (archive_read_data_block(a, &buf, &sz, &off) == ARCHIVE_OK)
                    archive_write_data_block(ext, buf, sz, off);
            }
        }

        archive_read_close(a);  archive_read_free(a);
        archive_write_close(ext); archive_write_free(ext);
        return true;
    }

    // --------------------------------------------------------
    // Transaction helpers
    // --------------------------------------------------------
    struct Transaction {
        std::vector<std::string> install_order;
        std::vector<std::string> installed_so_far;
        bool committed = false;
    };

    void rollback(Transaction &tx) {
        if (tx.installed_so_far.empty()) return;
        warn("Rolling back transaction...");
        for (auto it = tx.installed_so_far.rbegin(); it != tx.installed_so_far.rend(); ++it) {
            uninstall_pkg(*it, true);
        }
        ok("Rollback complete");
    }

    // --------------------------------------------------------
    // Installation — Arch binary
    // --------------------------------------------------------
    bool install_arch(const Package &p) {
        std::cout << "  Installing: " << PINK << p.name << RESET << " " << p.version << "\n";
        std::string cached = pkg_cache_dir + "/" + p.filename;

        if (!fs::exists(cached)) {
            bool got = false;
            for (auto &m : ARCH_MIRRORS) {
                std::string url = m + "/" + p.repo + "/os/x86_64/" + p.filename;
                if (dl_file(url, cached, true)) { got = true; break; }
            }
            if (!got) { err("Failed to download " + p.name); return false; }
        }

        std::vector<std::string> files;
        if (!extract_pkg(cached, "", &files)) {
            err("Failed to extract " + p.name);
            fs::remove(cached);
            return false;
        }

        // Save manifest
        std::ofstream mf(manifest_dir + "/" + p.name + ".manifest");
        for (auto &file : files) mf << file << "\n";

        Package ip = p;
        ip.installed = true;
        installed[p.name] = ip;
        save_installed();
        return true;
    }

    // --------------------------------------------------------
    // Installation — Galactica source
    // --------------------------------------------------------
    bool install_galactica(const Package &p) {
        std::cout << "  Building: " << PINK << p.name << RESET << " " << p.version << "\n";

        char cwd_buf[PATH_MAX];
        if (!getcwd(cwd_buf, sizeof(cwd_buf))) { err("getcwd failed"); return false; }
        std::string old_cwd = cwd_buf;

        std::string build_path = build_dir + "/" + p.name;
        try {
            fs::remove_all(build_path);
            fs::create_directories(build_path);
        } catch (const std::exception &e) {
            err("Build dir error: " + std::string(e.what()));
            return false;
        }

        if (chdir(build_path.c_str()) != 0) {
            err("Cannot enter build dir: " + build_path);
            return false;
        }

        // Download source
        if (!p.url.empty()) {
            status("Downloading source...");
            std::string src_file;
            size_t sl = p.url.find_last_of('/');
            src_file = (sl != std::string::npos) ? p.url.substr(sl + 1) : p.name + ".tar.gz";

            if (!dl_file(p.url, src_file, true)) {
                err("Failed to download: " + p.url);
                chdir(old_cwd.c_str());
                return false;
            }

            if (src_file.find(".tar") != std::string::npos ||
                src_file.find(".tgz") != std::string::npos) {
                status("Extracting...");
                if (exec_shell("tar -xf " + src_file + " 2>/dev/null") != 0) {
                    err("Extraction failed");
                    chdir(old_cwd.c_str());
                    return false;
                }
            }
        }

        // Run build script if provided
        bool build_ok = true;
        if (!p.build_script.empty()) {
            status("Building...");
            std::ofstream script("build.sh");
            if (!script) { err("Cannot write build script"); chdir(old_cwd.c_str()); return false; }
            script << "#!/bin/sh\nset -e\n\n" << p.build_script << "\n";
            script.close();
            chmod("build.sh", 0755);
            build_ok = (run_script("build.sh") == 0);
        } else {
            // Auto-detect build system
            status("Auto-detecting build system...");
            std::string src_dir;
            for (auto &e : fs::directory_iterator("."))
                if (e.is_directory()) { src_dir = e.path().string(); break; }
            if (!src_dir.empty()) chdir(src_dir.c_str());

            std::string cfg_flags = p.build_flags.count("configure_flags")
                ? p.build_flags.at("configure_flags") : "--prefix=/usr";
            std::string mk_flags = p.build_flags.count("make_flags")
                ? p.build_flags.at("make_flags") : "-j$(nproc)";

            if (fs::exists("configure"))
                build_ok = (exec_shell("./configure " + cfg_flags + " 2>&1") == 0);

            if (build_ok && (fs::exists("Makefile") || fs::exists("makefile"))) {
                build_ok = (exec_shell("make " + mk_flags + " 2>&1") == 0);
                if (build_ok) {
                    std::string inst = p.build_flags.count("install_target")
                        ? p.build_flags.at("install_target") : "install";
                    build_ok = (exec_shell("make " + inst + " 2>&1") == 0);
                }
            }
        }

        chdir(old_cwd.c_str());

        if (!build_ok) {
            err("Build failed for " + p.name);
            return false;
        }

        // Run post-install script if present
        if (!p.post_install.empty()) {
            status("Running post-install...");
            std::string post_path = build_dir + "/" + p.name + "_postinstall.sh";
            std::ofstream pf(post_path);
            pf << "#!/bin/sh\nset -e\n\n";
            for (auto &line : p.post_install) pf << line << "\n";
            pf.close();
            chmod(post_path.c_str(), 0755);
            if (run_script(post_path) != 0)
                warn("Post-install script failed (non-fatal)");
            fs::remove(post_path);
        }

        Package ip = p;
        ip.installed = true;
        installed[p.name] = ip;
        save_installed();
        return true;
    }

    // --------------------------------------------------------
    // Uninstall
    // --------------------------------------------------------
    bool uninstall_pkg(const std::string &name, bool silent = false) {
        auto it = installed.find(name);
        if (it == installed.end()) {
            if (!silent) err("Not installed: " + name);
            return false;
        }

        if (!silent) status("Uninstalling: " + name);
        Package &p = it->second;

        if (p.source == PackageSource::MODULE) {
            auto mit = modules.find(name);
            if (mit != modules.end()) {
                if (mit->second.cleanup) mit->second.cleanup();
                dlclose(mit->second.handle);
                modules.erase(mit);
            }
            fs::remove(modules_dir + "/" + name + ".so");
        } else {
            std::string mf_path = manifest_dir + "/" + name + ".manifest";
            if (fs::exists(mf_path)) {
                std::ifstream mf(mf_path);
                std::vector<std::string> files;
                std::string line;
                while (std::getline(mf, line))
                    if (!line.empty()) files.push_back(line);
                // Remove deepest paths first
                std::sort(files.rbegin(), files.rend());
                int removed = 0;
                for (auto &file : files) {
                    try {
                        if (fs::exists(file)) { fs::remove(file); removed++; }
                    } catch (...) {}
                }
                fs::remove(mf_path);
                if (!silent) ok("Removed " + std::to_string(removed) + " files");
            } else {
                if (!silent) warn("No manifest found, removing from database only");
            }
        }

        installed.erase(name);
        save_installed();
        if (!silent) ok("Uninstalled: " + name);
        return true;
    }

    // --------------------------------------------------------
    // Upgrade
    // --------------------------------------------------------
    bool upgrade_pkg(const std::string &name) {
        auto iit = installed.find(name);
        if (iit == installed.end()) { err("Not installed: " + name); return false; }

        auto pit = packages.find(name);
        if (pit == packages.end()) { err("Not in database: " + name); return false; }

        if (iit->second.version == pit->second.version) {
            ok(name + " is already up to date (" + iit->second.version + ")");
            return true;
        }

        std::cout << CYAN << name << RESET << ": " << iit->second.version
                  << " -> " << pit->second.version << "\n";

        // Uninstall old, install new
        if (!uninstall_pkg(name, true)) return false;

        if (pit->second.source == PackageSource::ARCH_BINARY)
            return install_arch(pit->second);
        return install_galactica(pit->second);
    }

    // --------------------------------------------------------
    // Module loading
    // --------------------------------------------------------
    bool load_mod(const std::string &path) {
        dbg("Loading module: " + path);
        void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!h) { err("dlopen: " + std::string(dlerror())); return false; }

        auto info_fn = (dreamland_module_info_fn)dlsym(h, "dreamland_module_info");
        if (!info_fn) { err("Module missing info function"); dlclose(h); return false; }

        DreamlandModuleInfo *info = info_fn();
        if (!info || info->api_version != DREAMLAND_MODULE_API_VERSION) {
            err("Module API version mismatch: " + path);
            dlclose(h);
            return false;
        }

        LoadedModule m;
        m.handle  = h;
        m.info    = info;
        m.cleanup = (dreamland_module_cleanup_fn)dlsym(h, "dreamland_module_cleanup");

        auto init_fn = (dreamland_module_init_fn)dlsym(h, "dreamland_module_init");
        if (init_fn && init_fn() != 0) { err("Module init failed"); dlclose(h); return false; }

        auto cmd_fn = (dreamland_module_commands_fn)dlsym(h, "dreamland_module_commands");
        if (cmd_fn) {
            int cnt = 0;
            DreamlandCommand *cmds = cmd_fn(&cnt);
            for (int i = 0; i < cnt; i++) m.commands.push_back(cmds[i]);
        }

        modules[info->name] = m;
        dbg("Loaded module: " + std::string(info->name));
        return true;
    }

    void load_all_mods() {
        for (auto &dir : module_search_paths) {
            if (!fs::exists(dir)) continue;
            for (auto &e : fs::directory_iterator(dir)) {
                if (e.path().extension() != ".so") continue;
                std::string name = e.path().stem().string();
                if (!modules.count(name)) load_mod(e.path().string());
            }
        }
    }

    void unload_mods() {
        for (auto &[n, m] : modules) {
            if (m.cleanup) m.cleanup();
            dlclose(m.handle);
        }
        modules.clear();
    }

public:
    Dreamland() {
        init();
        curl_global_init(CURL_GLOBAL_DEFAULT);
        load_all_mods();
    }
    ~Dreamland() {
        unload_mods();
        curl_global_cleanup();
    }

    // --------------------------------------------------------
    // Public commands
    // --------------------------------------------------------
    void sync() {
        banner();

        // Wipe old db cache so we always get fresh data
        std::error_code ec;
        if (fs::exists(db_cache_dir)) fs::remove_all(db_cache_dir, ec);
        fs::create_directories(db_cache_dir);

        fetch_galactica();
        load_galactica_packages();
        sync_arch();
        save_pkg_db();
        load_installed();

        ok("Sync complete — " + std::to_string(packages.size()) + " packages available");
    }

    void search(const std::string &q) {
        if (packages.empty()) load_pkg_db();
        load_installed();

        std::string lq = q;
        std::transform(lq.begin(), lq.end(), lq.begin(), ::tolower);

        bool found = false;
        for (auto &[n, p] : packages) {
            std::string ln = n, ld = p.description;
            std::transform(ln.begin(), ln.end(), ln.begin(), ::tolower);
            std::transform(ld.begin(), ld.end(), ld.begin(), ::tolower);
            if (ln.find(lq) == std::string::npos && ld.find(lq) == std::string::npos) continue;

            std::string tag = p.source == PackageSource::GALACTICA
                ? (CYAN "[galactica]" RESET) : (YELLOW "[arch]" RESET);
            std::cout << PINK << n << RESET << " " << p.version << " " << tag;
            if (installed.count(n)) std::cout << GREEN " [installed]" RESET;
            std::cout << "\n";
            if (!p.description.empty())
                std::cout << "    " << p.description << "\n";
            found = true;
        }
        if (!found) warn("No packages found matching: " + q);
    }

    void info(const std::string &name) {
        if (packages.empty()) load_pkg_db();
        load_installed();

        auto it = packages.find(name);
        if (it == packages.end()) { err("Package not found: " + name); return; }
        auto &p = it->second;

        std::cout << PINK << p.name << RESET << " " << p.version << "\n";
        std::cout << "  Description: " << p.description << "\n";
        std::cout << "  Source:      "
                  << (p.source == PackageSource::GALACTICA ? "Galactica (source)" : "Arch (binary)") << "\n";
        if (!p.repo.empty())     std::cout << "  Repo:        " << p.repo << "\n";
        if (!p.category.empty()) std::cout << "  Category:    " << p.category << "\n";
        if (p.size > 0)
            std::cout << "  Size:        " << (p.size / 1024) << " KB\n";
        if (!p.dependencies.empty()) {
            std::cout << "  Depends:     ";
            for (size_t i = 0; i < p.dependencies.size(); i++) {
                if (i) std::cout << ", ";
                std::cout << p.dependencies[i];
            }
            std::cout << "\n";
        }
        if (installed.count(name))
            std::cout << "  Status:      " << GREEN << "installed" << RESET << "\n";
    }

    bool install(const std::string &name) {
        if (packages.empty()) load_pkg_db();
        load_installed();

        if (installed.count(name)) { warn(name + " is already installed"); return true; }

        auto it = packages.find(name);
        if (it == packages.end()) { err("Package not found: " + name); return false; }

        const Package &pkg = it->second;

        // Resolve full dep tree
        status("Resolving dependencies...");
        std::set<std::string> resolved, visited;
        auto order = resolve_dependencies(name, resolved, visited);

        if (order.empty()) { err("Dependency resolution failed for " + name); return false; }

        // Show plan
        std::cout << "\n" << CYAN << "Packages to install (" << order.size() << "):" << RESET << "\n";
        size_t total_size = 0;
        for (auto &pname : order) {
            auto pit = packages.find(pname);
            if (pit == packages.end()) continue;
            total_size += pit->second.size;
            std::cout << "  " << pname << " " << YELLOW << pit->second.version << RESET << "\n";
        }
        if (total_size > 0) {
            std::cout << "\n" << CYAN << "Download size: " << RESET;
            if      (total_size < 1024)        std::cout << total_size << " B\n";
            else if (total_size < 1024 * 1024) std::cout << (total_size / 1024.0) << " KB\n";
            else                               std::cout << (total_size / (1024.0 * 1024.0)) << " MB\n";
        }

        std::cout << "\nProceed? [Y/n]: ";
        std::string ans;
        std::getline(std::cin, ans);
        if (!ans.empty() && ans[0] != 'y' && ans[0] != 'Y') {
            std::cout << "Cancelled.\n";
            return false;
        }

        // Install with transaction support
        Transaction tx;
        tx.install_order = order;
        std::cout << "\n";

        for (auto &pname : order) {
            auto pit = packages.find(pname);
            if (pit == packages.end()) continue;
            if (installed.count(pname)) continue;

            bool ok_install = pit->second.source == PackageSource::ARCH_BINARY
                ? install_arch(pit->second)
                : install_galactica(pit->second);

            if (!ok_install) {
                err("Failed to install " + pname);
                rollback(tx);
                return false;
            }
            tx.installed_so_far.push_back(pname);
        }

        tx.committed = true;
        ok("Installed " + name);
        return true;
    }

    bool uninstall(const std::string &name) {
        load_installed();
        return uninstall_pkg(name);
    }

    bool upgrade(const std::string &name) {
        if (packages.empty()) load_pkg_db();
        load_installed();
        return upgrade_pkg(name);
    }

    void upgrade_all() {
        if (packages.empty()) load_pkg_db();
        load_installed();
        banner();
        status("Checking for upgrades...");
        std::vector<std::string> upgradeable;
        for (auto &[n, p] : installed) {
            auto pit = packages.find(n);
            if (pit != packages.end() && pit->second.version != p.version)
                upgradeable.push_back(n);
        }
        if (upgradeable.empty()) { ok("Everything is up to date"); return; }
        std::cout << CYAN << upgradeable.size() << " upgrades available:\n" << RESET;
        for (auto &n : upgradeable) {
            auto &ip = installed[n];
            auto &pp = packages[n];
            std::cout << "  " << n << ": " << ip.version << " -> " << pp.version << "\n";
        }
        std::cout << "\nProceed? [Y/n]: ";
        std::string ans;
        std::getline(std::cin, ans);
        if (!ans.empty() && ans[0] != 'y' && ans[0] != 'Y') { std::cout << "Cancelled.\n"; return; }
        for (auto &n : upgradeable) upgrade_pkg(n);
        ok("Upgrade complete");
    }

    void list() {
        banner();
        load_installed();
        if (installed.empty()) { warn("Nothing installed"); return; }
        for (auto &[n, p] : installed) {
            std::string t = p.source == PackageSource::MODULE    ? PINK "[module]"   RESET
                          : p.source == PackageSource::GALACTICA ? CYAN "[source]"   RESET
                                                                 : YELLOW "[binary]" RESET;
            std::cout << "  " << n << " " << p.version << " " << t << "\n";
        }
    }

    void list_mods() {
        banner();
        std::cout << "Modules (" << modules.size() << "):\n\n";
        if (modules.empty()) {
            std::cout << "  None. Install with: dreamland install module-<name>\n";
            return;
        }
        for (auto &[n, m] : modules) {
            std::cout << PINK << "  " << m.info->name << RESET << " v" << m.info->version << "\n";
            std::cout << "    " << m.info->description << "\n";
            for (auto &c : m.commands)
                std::cout << "    " << CYAN << c.name << RESET << " — " << c.description << "\n";
            std::cout << "\n";
        }
    }

    void clean() {
        status("Cleaning package cache...");
        size_t freed = 0;
        if (fs::exists(pkg_cache_dir)) {
            for (auto &e : fs::directory_iterator(pkg_cache_dir)) {
                freed += fs::file_size(e.path());
                fs::remove(e.path());
            }
        }
        if (fs::exists(build_dir)) fs::remove_all(build_dir);
        fs::create_directories(build_dir);
        ok("Freed " + std::to_string(freed / (1024 * 1024)) + " MB");
    }

    bool has_cmd(const std::string &cmd) {
        for (auto &[n, m] : modules)
            for (auto &c : m.commands)
                if (cmd == c.name) return true;
        return false;
    }

    bool run_cmd(int argc, char **argv) {
        if (argc < 2) return false;
        std::string cmd = argv[1];
        for (auto &[n, m] : modules)
            for (auto &c : m.commands)
                if (cmd == c.name) return c.handler(argc - 1, argv + 1) == 0;
        return false;
    }

    void usage(const std::string &prog) {
        banner();
        std::cout << "Usage: " << prog << " <command> [args]\n\n";
        std::cout << CYAN << "Package management:\n" << RESET;
        std::cout << "  sync                  Sync package databases\n";
        std::cout << "  install <pkg>         Install a package\n";
        std::cout << "  uninstall <pkg>       Uninstall a package\n";
        std::cout << "  upgrade <pkg>         Upgrade a specific package\n";
        std::cout << "  upgrade-all           Upgrade all installed packages\n";
        std::cout << "  search <query>        Search packages\n";
        std::cout << "  info <pkg>            Show package details\n";
        std::cout << "  list                  List installed packages\n";
        std::cout << "  clean                 Clear package cache\n";
        std::cout << CYAN << "\nModules:\n" << RESET;
        std::cout << "  modules               List loaded modules\n";
        if (!modules.empty()) {
            std::cout << CYAN << "\nModule commands:\n" << RESET;
            for (auto &[n, m] : modules)
                for (auto &c : m.commands)
                    std::cout << "  " << c.name
                              << std::string(std::max(1, 22 - (int)strlen(c.name)), ' ')
                              << c.description << " [" << m.info->name << "]\n";
        }
    }
};

// ============================================================
// Entry point
// ============================================================
int main(int argc, char *argv[]) {
    Dreamland dl;
    if (argc < 2) { dl.usage(argv[0]); return 1; }

    std::string cmd = argv[1];

    // Module commands take priority
    if (dl.has_cmd(cmd)) return dl.run_cmd(argc, argv) ? 0 : 1;

    if      (cmd == "sync")                      dl.sync();
    else if (cmd == "search"      && argc >= 3)  dl.search(argv[2]);
    else if (cmd == "info"        && argc >= 3)  dl.info(argv[2]);
    else if (cmd == "install"     && argc >= 3)  return dl.install(argv[2])   ? 0 : 1;
    else if (cmd == "uninstall"   && argc >= 3)  return dl.uninstall(argv[2]) ? 0 : 1;
    else if (cmd == "upgrade"     && argc >= 3)  return dl.upgrade(argv[2])   ? 0 : 1;
    else if (cmd == "upgrade-all")               dl.upgrade_all();
    else if (cmd == "list")                      dl.list();
    else if (cmd == "modules")                   dl.list_mods();
    else if (cmd == "clean")                     dl.clean();
    else                                         { dl.usage(argv[0]); return 1; }

    return 0;
}
