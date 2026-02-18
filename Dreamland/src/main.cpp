#include "../include/dreamland_module.h"
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

namespace fs = std::filesystem;

#define PINK "\033[38;5;213m"
#define BLUE "\033[38;5;117m"
#define GREEN "\033[0;32m"
#define YELLOW "\033[1;33m"
#define RED "\033[0;31m"
#define CYAN "\033[0;36m"
#define RESET "\033[0m"

#define GALACTICA_REPO "LinkNavi/GalacticaRepository"
#define GALACTICA_RAW_URL                                                      \
  "https://raw.githubusercontent.com/" GALACTICA_REPO "/main/"

const std::vector<std::string> ARCH_MIRRORS = {
    "https://mirror.rackspace.com/archlinux",
    "https://mirrors.kernel.org/archlinux", "https://geo.mirror.pkgbuild.com"};
const std::vector<std::string> ARCH_REPOS = {"core", "extra"};

enum class PackageSource { GALACTICA, ARCH_BINARY, MODULE, UNKNOWN };

struct Package {
  std::string name, version, description, url, category, repo, filename,
      build_script;
  std::vector<std::string> dependencies;
  std::map<std::string, std::string> build_flags;
  bool installed = false, deps_resolved = false;
  PackageSource source = PackageSource::UNKNOWN;
  size_t size = 0;
};

struct LoadedModule {
  void *handle;
  DreamlandModuleInfo *info;
  std::vector<DreamlandCommand> commands;
  dreamland_module_cleanup_fn cleanup;
};

static size_t write_cb(void *c, size_t s, size_t n, std::string *o) {
  o->append((char *)c, s * n);
  return s * n;
}
static size_t write_file_cb(void *c, size_t s, size_t n, FILE *f) {
  return fwrite(c, s, n, f);
}

class Dreamland {
  std::string cache_dir, pkg_db, build_dir, installed_db, pkg_index,
      pkg_cache_dir, db_cache_dir, manifest_dir, modules_dir;
  bool debug = false;
  std::map<std::string, Package> packages, installed;
  std::set<std::string> galactica_pkgs;
  std::map<std::string, LoadedModule> modules;
  std::vector<std::string> module_search_paths;
  std::string home() {
    const char *h = getenv("HOME");
    return h ? h : "/tmp";
  }

  void init() {
    std::string h = home();
    const char *xc = getenv("XDG_CACHE_HOME");
    const char *xd = getenv("XDG_DATA_HOME");
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

    // Search paths for modules (system first, then user)
    module_search_paths = {"/usr/local/share/dreamland/modules",
                           bd + "/dreamland/modules"};

    // Use first writable directory for installs
    for (auto &path : module_search_paths) {
      if (fs::exists(path) && access(path.c_str(), W_OK) == 0) {
        modules_dir = path;
        break;
      }
    }
    if (modules_dir.empty())
      modules_dir = module_search_paths.back();

    debug = getenv("DREAMLAND_DEBUG") &&
            std::string(getenv("DREAMLAND_DEBUG")) == "1";

    fs::create_directories(cache_dir);
    fs::create_directories(build_dir);
    fs::create_directories(pkg_cache_dir);
    fs::create_directories(db_cache_dir);
    fs::create_directories(fs::path(installed_db).parent_path());
    fs::create_directories(manifest_dir);

    // Try to create modules directory
    try {
      fs::create_directories(modules_dir);
    } catch (...) {
    }
  }

  void load_all_mods() {
    for (auto &dir : module_search_paths) {
      if (!fs::exists(dir))
        continue;
      for (auto &e : fs::directory_iterator(dir)) {
        if (e.path().extension() == ".so") {
          std::string name = e.path().stem().string();
          // Skip if already loaded
          if (modules.find(name) != modules.end())
            continue;
          load_mod(e.path().string());
        }
      }
    }
  }

  std::string get_cache_dir() const { return cache_dir; }
  void banner() {
    std::cout << PINK << "    ★ DREAMLAND ★\n    User's Choice\n"
              << RESET << "\n";
  }
  void status(const std::string &m) {
    std::cout << BLUE << "[★] " << RESET << m << "\n";
  }
  void ok(const std::string &m) {
    std::cout << GREEN << "[✓] " << RESET << m << "\n";
  }
  void err(const std::string &m) {
    std::cerr << RED << "[✗] " << RESET << m << "\n";
  }
  void warn(const std::string &m) {
    std::cout << YELLOW << "[!] " << RESET << m << "\n";
  }
  void dbg(const std::string &m) {
    if (debug)
      std::cout << "[D] " << m << "\n";
  }

  bool dl_str(const std::string &url, std::string &out) {
    CURL *c = curl_easy_init();
    if (!c)
      return false;
    curl_easy_setopt(c, CURLOPT_URL, url.c_str());
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &out);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 30L);
    CURLcode r = curl_easy_perform(c);
    long rc;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &rc);
    curl_easy_cleanup(c);
    return r == CURLE_OK && rc == 200;
  }

  bool dl_file(const std::string &url, const std::string &path) {
    // If already cached and valid, return success
    if (fs::exists(path) && fs::file_size(path) > 0) {
      dbg("Using cached file: " + path);
      return true;
    }

    CURL *c = curl_easy_init();
    if (!c) {
      err("Failed to initialize CURL");
      return false;
    }

    // Create parent directories
    try {
      fs::create_directories(fs::path(path).parent_path());
    } catch (const std::exception &e) {
      err("Failed to create directory: " + std::string(e.what()));
      curl_easy_cleanup(c);
      return false;
    }

    FILE *f = fopen(path.c_str(), "wb");
    if (!f) {
      err("Failed to open file for writing: " + path);
      curl_easy_cleanup(c);
      return false;
    }

    curl_easy_setopt(c, CURLOPT_URL, url.c_str());
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_file_cb);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, f);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(c, CURLOPT_FAILONERROR, 1L); // Fail on HTTP errors

    // Add progress callback for large files
    if (debug) {
      dbg("Downloading: " + url);
    }

    CURLcode r = curl_easy_perform(c);
    long rc;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &rc);

    fclose(f);
    curl_easy_cleanup(c);

    if (r != CURLE_OK) {
      dbg("CURL error: " + std::string(curl_easy_strerror(r)));
      fs::remove(path);
      return false;
    }

    if (rc != 200) {
      dbg("HTTP error: " + std::to_string(rc));
      fs::remove(path);
      return false;
    }

    // Verify file was downloaded
    if (!fs::exists(path) || fs::file_size(path) == 0) {
      dbg("Downloaded file is empty or missing");
      fs::remove(path);
      return false;
    }

    dbg("Downloaded " + std::to_string(fs::file_size(path)) + " bytes");
    return true;
  }

  int exec(const std::string &cmd) { return WEXITSTATUS(system(cmd.c_str())); }
  bool parse_arch_db_with_deps(const std::string &db, const std::string &repo) {
    std::string dir = db_cache_dir + "/" + repo;

    // Remove existing directory if it exists to ensure clean extraction
    std::error_code ec;
    if (fs::exists(dir)) {
      dbg("Removing old " + repo + " database directory");
      fs::remove_all(dir, ec);
    }

    fs::create_directories(dir);

    if (exec("tar -xzf " + db + " -C " + dir + " 2>/dev/null") != 0) {
      err("Failed to extract " + repo + " database");
      return false;
    }

    int cnt = 0;

    for (auto &e : fs::directory_iterator(dir)) {
      if (!e.is_directory())
        continue;

      std::string desc = e.path().string() + "/desc";
      std::string depends = e.path().string() + "/depends";

      if (!fs::exists(desc))
        continue;

      Package p;
      p.source = PackageSource::ARCH_BINARY;
      p.repo = repo;

      // Parse desc file
      std::ifstream f(desc);
      std::string l, sec;
      while (std::getline(f, l)) {
        if (l.empty())
          continue;
        if (l[0] == '%' && l.back() == '%') {
          sec = l.substr(1, l.size() - 2);
          continue;
        }
        if (sec == "NAME")
          p.name = l;
        else if (sec == "VERSION")
          p.version = l;
        else if (sec == "DESC" && p.description.empty())
          p.description = l;
        else if (sec == "FILENAME")
          p.filename = l;
        else if (sec == "CSIZE")
          try {
            p.size = std::stoull(l);
          } catch (...) {
          }
      }
      f.close();

      // Parse depends file if it exists
      if (fs::exists(depends)) {
        std::ifstream df(depends);
        std::string dl, dsec;
        while (std::getline(df, dl)) {
          if (dl.empty())
            continue;
          if (dl[0] == '%' && dl.back() == '%') {
            dsec = dl.substr(1, dl.size() - 2);
            continue;
          }
          if (dsec == "DEPENDS") {
            // Strip version constraints
            size_t pos = dl.find_first_of(">=<");
            if (pos != std::string::npos) {
              dl = dl.substr(0, pos);
            }
            p.dependencies.push_back(dl);
          }
        }
        df.close();
      }

      if (!p.name.empty() && packages.find(p.name) == packages.end()) {
        packages[p.name] = p;
        cnt++;
      }
    }

    ok(std::to_string(cnt) + " packages from " + repo);
    return cnt > 0;
  }
  bool load_mod(const std::string &path) {
    dbg("Loading: " + path);
    void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h) {
      err("dlopen: " + std::string(dlerror()));
      return false;
    }
    auto info_fn = (dreamland_module_info_fn)dlsym(h, "dreamland_module_info");
    if (!info_fn) {
      err("No info fn");
      dlclose(h);
      return false;
    }
    DreamlandModuleInfo *info = info_fn();
    if (!info || info->api_version != DREAMLAND_MODULE_API_VERSION) {
      err("API mismatch");
      dlclose(h);
      return false;
    }
    LoadedModule m;
    m.handle = h;
    m.info = info;
    m.cleanup =
        (dreamland_module_cleanup_fn)dlsym(h, "dreamland_module_cleanup");
    auto init_fn = (dreamland_module_init_fn)dlsym(h, "dreamland_module_init");
    if (init_fn && init_fn() != 0) {
      err("Init failed");
      dlclose(h);
      return false;
    }
    auto cmd_fn =
        (dreamland_module_commands_fn)dlsym(h, "dreamland_module_commands");
    if (cmd_fn) {
      int cnt = 0;
      DreamlandCommand *cmds = cmd_fn(&cnt);
      for (int i = 0; i < cnt; i++)
        m.commands.push_back(cmds[i]);
    }
    modules[info->name] = m;
    dbg("Loaded: " + std::string(info->name));
    return true;
  }

  void unload_mods() {
    for (auto &[n, m] : modules) {
      if (m.cleanup)
        m.cleanup();
      dlclose(m.handle);
    }
    modules.clear();
  }

  void save_pkg_db() {
    std::ofstream f(pkg_db);
    if (!f)
      return;
    for (auto &[n, p] : packages) {
      if (p.source == PackageSource::ARCH_BINARY) {
        f << "ARCH|" << p.name << "|" << p.version << "|" << p.repo << "|"
          << p.filename << "|" << p.size << "|" << p.description << "|"
          << (p.deps_resolved ? "1" : "0") << "\n";
      } else if (p.source == PackageSource::GALACTICA) {
        f << "GALACTICA|" << p.name << "|" << p.version << "|" << p.url << "|"
          << p.category << "|" << p.description << "\n";
      }
    }
  }

  // UPDATE load_pkg_db to also load Galactica packages
  void load_pkg_db() {
    std::ifstream f(pkg_db);
    if (!f)
      return;
    std::string l;
    while (std::getline(f, l)) {
      std::istringstream is(l);
      std::string type;
      std::getline(is, type, '|');

      if (type == "ARCH") {
        std::string n, v, r, fn, sz, d, dr;
        std::getline(is, n, '|');
        std::getline(is, v, '|');
        std::getline(is, r, '|');
        std::getline(is, fn, '|');
        std::getline(is, sz, '|');
        std::getline(is, d, '|');
        std::getline(is, dr, '|');

        Package p;
        p.name = n;
        p.version = v;
        p.repo = r;
        p.filename = fn;
        try {
          p.size = std::stoull(sz);
        } catch (...) {
        }
        p.description = d;
        p.source = PackageSource::ARCH_BINARY;
        p.deps_resolved = dr == "1";
        packages[n] = p;
      } else if (type == "GALACTICA") {
        std::string n, v, u, c, d;
        std::getline(is, n, '|');
        std::getline(is, v, '|');
        std::getline(is, u, '|');
        std::getline(is, c, '|');
        std::getline(is, d, '|');

        Package p;
        p.name = n;
        p.version = v;
        p.url = u;
        p.category = c;
        p.description = d;
        p.source = PackageSource::GALACTICA;
        packages[n] = p;
      }
    }
  }

std::string resolve_lib_to_pkg(const std::string& dep) {
    // If it's a .so file, try to find the package
    if (dep.find(".so") != std::string::npos) {
        std::string base = dep.substr(0, dep.find(".so"));
        
        // Try: libcurl.so -> libcurl
        if (packages.count(base)) return base;
        
        // Try: libcurl.so -> curl (strip "lib" prefix)
        if (base.substr(0, 3) == "lib") {
            std::string without_lib = base.substr(3);
            if (packages.count(without_lib)) return without_lib;
        }
        
        // Not found, return original
        dbg("Could not resolve library: " + dep);
    }
    
    return dep;
}

std::vector<std::string>
resolve_dependencies(const std::string &pkg_name,
                     std::set<std::string> &resolved,
                     std::set<std::string> &visited) {
    std::vector<std::string> install_order;

    // Avoid circular dependencies
    if (visited.count(pkg_name)) {
        return install_order;
    }
    visited.insert(pkg_name);

    // Skip if already installed
    if (installed.count(pkg_name)) {
        resolved.insert(pkg_name);
        return install_order;
    }

    // Find package in database
    auto it = packages.find(pkg_name);
    if (it == packages.end()) {
        warn("Dependency not found in database: " + pkg_name);
        return install_order;
    }

    const Package &pkg = it->second;

    // For Arch packages, we need to download to get dependencies
    if (pkg.source == PackageSource::ARCH_BINARY) {
        std::string cached = pkg_cache_dir + "/" + pkg.filename;

        if (!fs::exists(cached)) {
            dbg("Downloading " + pkg_name + " to resolve dependencies...");

            bool downloaded = false;
            for (auto &mirror : ARCH_MIRRORS) {
                std::string url =
                    mirror + "/" + pkg.repo + "/os/x86_64/" + pkg.filename;
                dbg("Trying mirror: " + mirror);

                if (dl_file(url, cached)) {
                    downloaded = true;
                    dbg("Downloaded from: " + mirror);
                    break;
                }
            }

            if (!downloaded) {
                // Try to get dependencies from the database 'depends' file instead
                warn("Could not download " + pkg_name +
                     ", using database dependencies");

                // Use dependencies from parse_arch_db_with_deps if available
                for (const auto &dep : pkg.dependencies) {
                    std::string resolved_dep = resolve_lib_to_pkg(dep);
                    if (!resolved.count(resolved_dep)) {
                        auto dep_order = resolve_dependencies(resolved_dep, resolved, visited);
                        install_order.insert(install_order.end(), dep_order.begin(), dep_order.end());
                    }
                }

                // Still add this package to install order
                if (!resolved.count(pkg_name)) {
                    install_order.push_back(pkg_name);
                    resolved.insert(pkg_name);
                }

                return install_order;
            }
        }

        // Extract dependencies from .PKGINFO
        std::vector<std::string> deps = extract_pkginfo_deps(cached);

        // Recursively resolve dependencies
        for (const auto &dep : deps) {
            std::string resolved_dep = resolve_lib_to_pkg(dep);
            if (!resolved.count(resolved_dep)) {
                auto dep_order =
                    resolve_dependencies(resolved_dep, resolved, visited);
                install_order.insert(install_order.end(), dep_order.begin(),
                                   dep_order.end());
            }
        }
    } else if (pkg.source == PackageSource::GALACTICA) {
        // For Galactica packages, use dependencies from .pkg file
        for (const auto &dep : pkg.dependencies) {
            std::string resolved_dep = resolve_lib_to_pkg(dep);
            if (!resolved.count(resolved_dep)) {
                auto dep_order = resolve_dependencies(resolved_dep, resolved, visited);
                install_order.insert(install_order.end(), dep_order.begin(),
                                   dep_order.end());
            }
        }
    }

    // Add this package to install order
    if (!resolved.count(pkg_name)) {
        install_order.push_back(pkg_name);
        resolved.insert(pkg_name);
    }

    return install_order;
}

std::vector<std::string> extract_pkginfo_deps(const std::string &pkg_path) {
    std::vector<std::string> deps;

    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    if (archive_read_open_filename(a, pkg_path.c_str(), 10240) != ARCHIVE_OK) {
        archive_read_free(a);
        return deps;
    }

    struct archive_entry *entry;
    bool found_pkginfo = false;

    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        std::string pathname = archive_entry_pathname(entry);

        if (pathname == ".PKGINFO") {
            found_pkginfo = true;

            // Read the entire .PKGINFO file
            size_t size = archive_entry_size(entry);
            std::vector<char> buffer(size + 1);

            ssize_t bytes_read = archive_read_data(a, buffer.data(), size);
            if (bytes_read > 0) {
                buffer[bytes_read] = '\0';
                std::string content(buffer.data());

                // Parse dependencies from .PKGINFO
                std::istringstream iss(content);
                std::string line;

                while (std::getline(iss, line)) {
                    // Dependencies are in format: depend = package-name>=version
                    // or: depend = package-name
                    if (line.find("depend = ") == 0) {
                        std::string dep = line.substr(9); // Skip "depend = "

                        // Strip version constraints (>=, <=, =, <, >)
                        size_t pos = dep.find_first_of(">=<");
                        if (pos != std::string::npos) {
                            dep = dep.substr(0, pos);
                        }

                        // Trim whitespace
                        dep.erase(0, dep.find_first_not_of(" \t\r\n"));
                        dep.erase(dep.find_last_not_of(" \t\r\n") + 1);

                        if (!dep.empty()) {
                            deps.push_back(dep);
                        }
                    }
                }
            }
            break;
        }
    }

    archive_read_close(a);
    archive_read_free(a);

    if (!found_pkginfo) {
        dbg("No .PKGINFO found in " + pkg_path);
    } else {
        dbg("Found " + std::to_string(deps.size()) + " dependencies in .PKGINFO");
    }

    return deps;
}  

  bool fetch_galactica() {
    status("Fetching Galactica index...");
    std::string content;
    if (!dl_str(GALACTICA_RAW_URL "INDEX", content)) {
      err("Failed");
      return false;
    }
    std::ofstream(pkg_index) << content;
    galactica_pkgs.clear();
    std::istringstream is(content);
    std::string l;
    while (std::getline(is, l)) {
      l.erase(0, l.find_first_not_of(" \t\r\n"));
      l.erase(l.find_last_not_of(" \t\r\n") + 1);
      if (!l.empty() && l[0] != '#')
        galactica_pkgs.insert(l);
    }
    ok(std::to_string(galactica_pkgs.size()) + " Galactica packages");
    return true;
  }

  bool parse_arch_db(const std::string &db, const std::string &repo) {
    std::string dir = db_cache_dir + "/" + repo;
    fs::create_directories(dir);
    if (exec("tar -xzf " + db + " -C " + dir + " 2>/dev/null") != 0)
      return false;
    int cnt = 0;
    for (auto &e : fs::directory_iterator(dir)) {
      if (!e.is_directory())
        continue;
      std::string desc = e.path().string() + "/desc";
      if (!fs::exists(desc))
        continue;
      Package p;
      p.source = PackageSource::ARCH_BINARY;
      p.repo = repo;
      std::ifstream f(desc);
      std::string l, sec;
      while (std::getline(f, l)) {
        if (l.empty())
          continue;
        if (l[0] == '%' && l.back() == '%') {
          sec = l.substr(1, l.size() - 2);
          continue;
        }
        if (sec == "NAME")
          p.name = l;
        else if (sec == "VERSION")
          p.version = l;
        else if (sec == "DESC" && p.description.empty())
          p.description = l;
        else if (sec == "FILENAME")
          p.filename = l;
        else if (sec == "CSIZE")
          try {
            p.size = std::stoull(l);
          } catch (...) {
          }
      }
      if (!p.name.empty() && packages.find(p.name) == packages.end()) {
        packages[p.name] = p;
        cnt++;
      }
    }
    ok(std::to_string(cnt) + " from " + repo);
    return cnt > 0;
  }

  // Load all Galactica packages from INDEX
  bool load_galactica_packages() {
    if (galactica_pkgs.empty()) {
      dbg("No Galactica packages in INDEX");
      return false;
    }

    int loaded = 0;
    for (const auto &pkg_path : galactica_pkgs) {
      if (parse_galactica_pkg(pkg_path)) {
        loaded++;
      }
    }

    if (loaded > 0) {
      ok("Loaded " + std::to_string(loaded) + " Galactica packages");
      return true;
    }

    return false;
  }

  // Install a Galactica package (source-based)
  bool install_galactica(const Package &p) {
    std::cout << "Installing from source: " << PINK << p.name << RESET << " "
              << p.version << "\n";

    // Get current working directory FIRST (before any fs operations)
    char cwd_buffer[PATH_MAX];
    if (getcwd(cwd_buffer, sizeof(cwd_buffer)) == nullptr) {
      err("Failed to get current directory");
      return false;
    }
    std::string old_cwd = cwd_buffer;

    // Create build directory with better error handling
    std::string build_path = build_dir + "/" + p.name;

    try {
      // Ensure parent exists first
      if (!fs::exists(build_dir)) {
        fs::create_directories(build_dir);
      }

      // Create package build directory
      if (!fs::exists(build_path)) {
        fs::create_directory(build_path);
      }
    } catch (const fs::filesystem_error &e) {
      err("Failed to create build directory: " + std::string(e.what()));
      err("Build dir: " + build_dir);
      err("Package dir: " + build_path);
      return false;
    }

    // Change to build directory
    if (chdir(build_path.c_str()) != 0) {
      err("Failed to change to build directory: " + build_path);
      return false;
    }

    dbg("Working in: " + build_path);

    // Download source
    if (!p.url.empty()) {
      status("Downloading source...");

      // Extract filename from URL
      std::string src_file;
      size_t last_slash = p.url.find_last_of('/');
      if (last_slash != std::string::npos) {
        src_file = p.url.substr(last_slash + 1);
      } else {
        src_file = p.name + ".tar.gz";
      }

      dbg("Downloading to: " + src_file);

      if (!dl_file(p.url, src_file)) {
        err("Failed to download source from: " + p.url);
        chdir(old_cwd.c_str());
        return false;
      }

      // Only extract if it's an archive
      if (src_file.find(".tar") != std::string::npos ||
          src_file.find(".tgz") != std::string::npos) {
        status("Extracting...");
        if (exec("tar -xf " + src_file + " 2>/dev/null") != 0) {
          err("Failed to extract source");
          chdir(old_cwd.c_str());
          return false;
        }
      }
    }

    // Execute build script
    if (!p.build_script.empty()) {
      status("Building...");

      // Write script to file
      std::ofstream script("build.sh");
      if (!script.is_open()) {
        err("Failed to create build script");
        chdir(old_cwd.c_str());
        return false;
      }

      script << "#!/bin/sh\n";
      script << "set -e\n\n";
      script << p.build_script << "\n";
      script.close();

      chmod("build.sh", 0755);

      // Execute
      int result = system("sh build.sh 2>&1");
      if (result != 0) {
        err("Build failed with exit code: " +
            std::to_string(WEXITSTATUS(result)));
        chdir(old_cwd.c_str());
        return false;
      }
    } else {
      // Default build process
      status("Building with default commands...");

      // Try to find the extracted directory
      std::string src_dir;
      try {
        for (auto &entry : fs::directory_iterator(".")) {
          std::string filename = entry.path().filename().string();
          if (entry.is_directory() && filename != "." && filename != "..") {
            src_dir = entry.path().string();
            dbg("Found source directory: " + src_dir);
            break;
          }
        }
      } catch (...) {
        dbg("No subdirectories found, building in current directory");
      }

      if (!src_dir.empty()) {
        if (chdir(src_dir.c_str()) != 0) {
          warn("Could not change to source directory, continuing in current "
               "directory");
        }
      }

      // Configure
      std::string configure_flags = p.build_flags.count("configure_flags")
                                        ? p.build_flags.at("configure_flags")
                                        : "--prefix=/usr";

      if (fs::exists("configure")) {
        status("Running configure...");
        if (exec("./configure " + configure_flags + " 2>&1") != 0) {
          err("Configure failed");
          chdir(old_cwd.c_str());
          return false;
        }
      }

      // Make
      std::string make_flags = p.build_flags.count("make_flags")
                                   ? p.build_flags.at("make_flags")
                                   : "-j$(nproc)";

      if (fs::exists("Makefile") || fs::exists("makefile")) {
        status("Running make...");
        if (exec("make " + make_flags + " 2>&1") != 0) {
          err("Make failed");
          chdir(old_cwd.c_str());
          return false;
        }

        // Install
        std::string install_target = p.build_flags.count("install_target")
                                         ? p.build_flags.at("install_target")
                                         : "install";

        status("Installing...");
        if (exec("make " + install_target + " 2>&1") != 0) {
          err("Install failed");
          chdir(old_cwd.c_str());
          return false;
        }
      } else {
        warn("No Makefile found, skipping build");
      }
    }

    // Return to original directory
    chdir(old_cwd.c_str());

    // Mark as installed
    Package ip = p;
    ip.installed = true;
    installed[p.name] = ip;
    save_installed();

    ok("Installed " + p.name);
    return true;
  }
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
      // Trim whitespace
      line.erase(0, line.find_first_not_of(" \t\r\n"));
      line.erase(line.find_last_not_of(" \t\r\n") + 1);

      if (line.empty() || line[0] == '#')
        continue;

      // Section headers
      if (line[0] == '[' && line.back() == ']') {
        section = line.substr(1, line.length() - 2);
        continue;
      }

      // Key-value pairs
      size_t eq = line.find('=');
      if (eq == std::string::npos)
        continue;

      std::string key = line.substr(0, eq);
      std::string value = line.substr(eq + 1);

      // Trim
      key.erase(key.find_last_not_of(" \t") + 1);
      value.erase(0, value.find_first_not_of(" \t"));

      // Remove quotes
      if (value.length() >= 2 && value[0] == '"' && value.back() == '"') {
        value = value.substr(1, value.length() - 2);
      }

      if (section == "Package") {
        if (key == "name")
          p.name = value;
        else if (key == "version")
          p.version = value;
        else if (key == "description")
          p.description = value;
        else if (key == "url")
          p.url = value;
        else if (key == "category")
          p.category = value;
      } else if (section == "Dependencies") {
        if (key == "depends") {
          // Parse space-separated dependencies
          std::istringstream deps(value);
          std::string dep;
          while (deps >> dep) {
            p.dependencies.push_back(dep);
          }
        }
      } else if (section == "Build") {
        p.build_flags[key] = value;
      } else if (section == "Script") {
        // Accumulate script lines
        if (!p.build_script.empty())
          p.build_script += "\n";
        p.build_script += line;
      }
    }

    // Only add if we got essential info
    if (!p.name.empty() && !p.version.empty()) {
      packages[p.name] = p;
      dbg("Loaded Galactica package: " + p.name);
      return true;
    }

    return false;
  }
  bool sync_arch() {
    status("Syncing Arch databases...");

    // Try each mirror until we get both repos successfully
    for (auto &mirror : ARCH_MIRRORS) {
      bool all_repos_ok = true;

      for (auto &repo : ARCH_REPOS) {
        std::string url = mirror + "/" + repo + "/os/x86_64/" + repo + ".db";
        std::string file = db_cache_dir + "/" + repo + ".db";

        dbg("Downloading " + repo + " database from " + mirror);

        if (!dl_file(url, file)) {
          dbg("Failed to download " + repo + " from " + mirror);
          all_repos_ok = false;
          break;
        }

        dbg("Parsing " + repo + " database");

        if (!parse_arch_db_with_deps(file, repo)) {
          dbg("Failed to parse " + repo + " database");
          all_repos_ok = false;
          break;
        }
      }

      // If all repos downloaded and parsed successfully, we're done
      if (all_repos_ok) {
        ok("Successfully synced from " + mirror);
        return true;
      }

      warn("Failed to sync all repos from " + mirror +
           ", trying next mirror...");
    }

    err("Failed to sync from all mirrors");
    return false;
  }

  bool extract_pkg(const std::string &pkg, const std::string &dest,
                   std::vector<std::string> *files = nullptr) {
    struct archive *a = archive_read_new(), *ext = archive_write_disk_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    archive_write_disk_set_options(ext,
                                   ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM);
    if (archive_read_open_filename(a, pkg.c_str(), 10240) != ARCHIVE_OK) {
      archive_read_free(a);
      archive_write_free(ext);
      return false;
    }
    struct archive_entry *entry;
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
      std::string pn = archive_entry_pathname(entry);
      if (pn[0] == '.' && (pn.find(".PKGINFO") != std::string::npos ||
                           pn.find(".MTREE") != std::string::npos))
        continue;
      std::string fp = dest + "/" + pn;
      archive_entry_set_pathname(entry, fp.c_str());
      if (archive_write_header(ext, entry) == ARCHIVE_OK) {
        if (files && archive_entry_filetype(entry) == AE_IFREG)
          files->push_back("/" + pn);
        const void *buf;
        size_t sz;
        int64_t off;
        while (archive_read_data_block(a, &buf, &sz, &off) == ARCHIVE_OK)
          archive_write_data_block(ext, buf, sz, off);
      }
    }
    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);
    return true;
  }

  void save_installed() {
    std::ofstream f(installed_db);
    if (!f)
      return;
    for (auto &[n, p] : installed) {
      std::string src = p.source == PackageSource::MODULE      ? "module"
                        : p.source == PackageSource::GALACTICA ? "galactica"
                                                               : "arch";
      f << n << " " << p.version << " " << src << "\n";
    }
  }

  void load_installed() {
    std::ifstream f(installed_db);
    if (!f)
      return;
    std::string l;
    while (std::getline(f, l)) {
      if (l.empty())
        continue;
      std::istringstream is(l);
      Package p;
      std::string src;
      is >> p.name >> p.version >> src;
      p.installed = true;
      p.source = src == "module"      ? PackageSource::MODULE
                 : src == "galactica" ? PackageSource::GALACTICA
                                      : PackageSource::ARCH_BINARY;
      installed[p.name] = p;
    }
  }

  bool install_arch(const Package &p) {
    std::cout << "Installing: " << PINK << p.name << RESET << " " << p.version
              << "\n";
    std::string cached = pkg_cache_dir + "/" + p.filename;
    if (!fs::exists(cached)) {
      status("Downloading...");
      for (auto &m : ARCH_MIRRORS) {
        if (dl_file(m + "/" + p.repo + "/os/x86_64/" + p.filename, cached))
          break;
      }
      if (!fs::exists(cached)) {
        err("Download failed");
        return false;
      }
    }
    std::vector<std::string> files;
    if (!extract_pkg(cached, "", &files)) {
      err("Extract failed");
      return false;
    }
    std::ofstream mf(manifest_dir + "/" + p.name + ".manifest");
    for (auto &f : files)
      mf << f << "\n";
    Package ip = p;
    ip.installed = true;
    installed[p.name] = ip;
    save_installed();
    ok("Installed " + p.name);
    return true;
  }

  bool uninstall_pkg(const std::string &name) {
    load_installed();
    auto it = installed.find(name);
    if (it == installed.end()) {
      err("Not installed: " + name);
      return false;
    }
    Package &p = it->second;
    status("Uninstalling: " + name);
    if (p.source == PackageSource::MODULE) {
      auto mit = modules.find(name);
      if (mit != modules.end()) {
        if (mit->second.cleanup)
          mit->second.cleanup();
        dlclose(mit->second.handle);
        modules.erase(mit);
      }
      std::string mod_path = modules_dir + "/" + name + ".so";
      if (fs::exists(mod_path))
        fs::remove(mod_path);
      ok("Module removed");
    } else {
      std::string mf = manifest_dir + "/" + name + ".manifest";
      if (fs::exists(mf)) {
        std::ifstream f(mf);
        std::string line;
        std::vector<std::string> files;
        while (std::getline(f, line))
          if (!line.empty())
            files.push_back(line);
        f.close();
        std::sort(files.rbegin(), files.rend());
        int removed = 0;
        for (auto &file : files) {
          try {
            if (fs::exists(file)) {
              fs::remove(file);
              removed++;
            }
          } catch (...) {
          }
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
  Dreamland() {
    init();
    curl_global_init(CURL_GLOBAL_DEFAULT);
    load_all_mods();
  }
  ~Dreamland() {
    unload_mods();
    curl_global_cleanup();
  }

  void sync() {
    banner();

    // Clear cache directory before syncing
    std::string cache_db_path = get_cache_dir() + "/db";

    // Remove the cache/db directory if it exists
    std::error_code ec;
    if (std::filesystem::exists(cache_db_path, ec)) {
      std::cout << "Removing old cache database..." << "\n";
      if (std::filesystem::remove_all(cache_db_path, ec)) {
        ok("Old cache removed");
      } else {
        warn("Failed to remove old cache: " + ec.message());
      }
    }

    // Fetch Galactica INDEX
    fetch_galactica();

    // Load Galactica package definitions
    load_galactica_packages();

    // Sync Arch databases
    sync_arch();

    // Save and load
    save_pkg_db();
    load_installed();

    ok("Sync complete");
    std::cout << "  " << packages.size() << " packages available\n";
    std::cout << "  " << modules.size() << " modules loaded\n";
  }

  void search(const std::string &q) {
    if (packages.empty())
      load_pkg_db();
    load_installed();
    for (auto &[n, p] : packages) {
      if (n.find(q) != std::string::npos ||
          p.description.find(q) != std::string::npos) {
        std::cout << PINK << n << RESET << " " << p.version
                  << (installed.count(n) ? GREEN " [installed]" RESET : "")
                  << "\n";
      }
    }
  }

  bool install(const std::string &name) {
    load_installed();
    if (packages.empty())
      load_pkg_db();

    // Check if already installed
    if (installed.count(name)) {
      warn(name + " already installed");
      return false;
    }

    // Find package
    auto it = packages.find(name);
    if (it == packages.end()) {
      err("Not found: " + name);
      return false;
    }

    const Package &pkg = it->second;

    // Handle based on source type
    if (pkg.source == PackageSource::GALACTICA) {
      // Source-based installation
      return install_galactica(pkg);
    } else if (pkg.source == PackageSource::ARCH_BINARY) {
      // Binary installation with dependency resolution
      status("Resolving dependencies for " + name + "...");
      std::set<std::string> resolved;
      std::set<std::string> visited;

      std::vector<std::string> install_order =
          resolve_dependencies(name, resolved, visited);

      if (install_order.empty()) {
        err("Dependency resolution failed");
        return false;
      }

      // Show installation plan
      std::cout << "\n"
                << CYAN << "Packages to install (" << install_order.size()
                << "):" << RESET << "\n";
      for (const auto &pkg_name : install_order) {
        auto pkg_it = packages.find(pkg_name);
        if (pkg_it != packages.end()) {
          std::cout << "  " << pkg_name << " " << YELLOW
                    << pkg_it->second.version << RESET << "\n";
        }
      }

      // Calculate total download size
      size_t total_size = 0;
      for (const auto &pkg_name : install_order) {
        auto pkg_it = packages.find(pkg_name);
        if (pkg_it != packages.end()) {
          total_size += pkg_it->second.size;
        }
      }

      std::cout << "\n" << CYAN << "Total download size: " << RESET;
      if (total_size < 1024) {
        std::cout << total_size << " B\n";
      } else if (total_size < 1024 * 1024) {
        std::cout << (total_size / 1024.0) << " KB\n";
      } else {
        std::cout << (total_size / (1024.0 * 1024.0)) << " MB\n";
      }

      std::cout << "\nProceed with installation? [Y/n]: ";
      std::string response;
      std::getline(std::cin, response);

      if (!response.empty() && response[0] != 'y' && response[0] != 'Y') {
        std::cout << "Installation cancelled.\n";
        return false;
      }

      // Install packages in dependency order
      std::cout << "\n";
      for (const auto &pkg_name : install_order) {
        auto pkg_it = packages.find(pkg_name);
        if (pkg_it != packages.end()) {
          if (!install_arch(pkg_it->second)) {
            err("Failed to install " + pkg_name);
            return false;
          }
        }
      }

      ok("Successfully installed " + name + " with " +
         std::to_string(install_order.size()) + " package(s)");

      return true;
    }

    err("Unknown package source");
    return false;
  }
  bool uninstall(const std::string &name) { return uninstall_pkg(name); }

  void list() {
    banner();
    load_installed();
    if (installed.empty()) {
      warn("Nothing installed");
      return;
    }
    for (auto &[n, p] : installed) {
      std::string t = p.source == PackageSource::MODULE ? PINK "[module]" RESET
                      : p.source == PackageSource::GALACTICA
                          ? CYAN "[source]" RESET
                          : YELLOW "[binary]" RESET;
      std::cout << "  " << n << " " << p.version << " " << t << "\n";
    }
  }

  void list_mods() {
    banner();
    std::cout << "Modules (" << modules.size() << "):\n\n";
    if (modules.empty()) {
      std::cout << "  None. Install: dreamland install module-<n>\n";
      return;
    }
    for (auto &[n, m] : modules) {
      std::cout << PINK << "  " << m.info->name << RESET << " v"
                << m.info->version << "\n";
      std::cout << "    " << m.info->description << "\n";
      for (auto &c : m.commands)
        std::cout << "      " << CYAN << c.name << RESET << " - "
                  << c.description << "\n";
      std::cout << "\n";
    }
  }

  bool has_cmd(const std::string &cmd) {
    for (auto &[n, m] : modules)
      for (auto &c : m.commands)
        if (cmd == c.name)
          return true;
    return false;
  }

  bool run_cmd(int argc, char **argv) {
    if (argc < 2)
      return false;
    std::string cmd = argv[1];
    for (auto &[n, m] : modules)
      for (auto &c : m.commands)
        if (cmd == c.name)
          return c.handler(argc - 1, argv + 1) == 0;
    return false;
  }

  void usage(const std::string &prog) {
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
      for (auto &[n, m] : modules)
        for (auto &c : m.commands)
          std::cout << "  " << c.name << std::string(14 - strlen(c.name), ' ')
                    << c.description << " [" << m.info->name << "]\n";
    }
  }
};

int main(int argc, char *argv[]) {
  Dreamland dl;
  if (argc < 2) {
    dl.usage(argv[0]);
    return 1;
  }
  std::string cmd = argv[1];
  if (dl.has_cmd(cmd))
    return dl.run_cmd(argc, argv) ? 0 : 1;
  if (cmd == "sync")
    dl.sync();
  else if (cmd == "search" && argc >= 3)
    dl.search(argv[2]);
  else if (cmd == "install" && argc >= 3)
    return dl.install(argv[2]) ? 0 : 1;
  else if (cmd == "uninstall" && argc >= 3)
    return dl.uninstall(argv[2]) ? 0 : 1;
  else if (cmd == "list")
    dl.list();
  else if (cmd == "modules")
    dl.list_mods();
  else {
    dl.usage(argv[0]);
    return 1;
  }
  return 0;
}
