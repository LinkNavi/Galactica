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
      build_script, type;
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

    module_search_paths = {"/usr/local/share/dreamland/modules",
                           bd + "/dreamland/modules"};

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
    if (fs::exists(path) && fs::file_size(path) > 0) {
      dbg("Using cached file: " + path);
      return true;
    }
    CURL *c = curl_easy_init();
    if (!c) {
      err("Failed to initialize CURL");
      return false;
    }
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
    curl_easy_setopt(c, CURLOPT_FAILONERROR, 1L);
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
    if (!fs::exists(path) || fs::file_size(path) == 0) {
      fs::remove(path);
      return false;
    }
    dbg("Downloaded " + std::to_string(fs::file_size(path)) + " bytes");
    return true;
  }

  int exec(const std::string &cmd) { return WEXITSTATUS(system(cmd.c_str())); }

  bool parse_arch_db_with_deps(const std::string &db, const std::string &repo) {
    std::string dir = db_cache_dir + "/" + repo;
    std::error_code ec;
    if (fs::exists(dir))
      fs::remove_all(dir, ec);
    fs::create_directories(dir);
    std::string tar_cmd = fs::exists("/bin/tar") ? "/bin/tar" : "busybox tar";
    if (exec(tar_cmd + " -xzf " + db + " -C " + dir + " 2>/dev/null") != 0) {
      err("Failed to extract " + repo + " database");
      return false;
    }
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
        l.erase(0, l.find_first_not_of(" \t\r\n"));
        l.erase(l.find_last_not_of(" \t\r\n") + 1);
        if (l.empty()) {
          sec = "";
          continue;
        }
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
        else if (sec == "DEPENDS") {
          size_t pos = l.find_first_of(">=<");
          std::string dep = (pos != std::string::npos) ? l.substr(0, pos) : l;
          size_t so_pos = dep.find(".so");
          if (so_pos != std::string::npos)
            dep = dep.substr(0, so_pos);
          if (!dep.empty())
            p.dependencies.push_back(dep);
        }
      }
      f.close();
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

  static std::string base64_encode(const std::string &in) {
    static const char *b64 =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve(((in.size() + 2) / 3) * 4);
    int val = 0, valb = -6;
    for (unsigned char c : in) {
      val = (val << 8) + c;
      valb += 8;
      while (valb >= 0) {
        out.push_back(b64[(val >> valb) & 0x3F]);
        valb -= 6;
      }
    }
    if (valb > -6)
      out.push_back(b64[((val << 8) >> (valb + 8)) & 0x3F]);
    while (out.size() % 4)
      out.push_back('=');
    return out;
  }

  static std::string base64_decode(const std::string &in) {
    static const int lookup[256] = {
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, 62, -1, -1, -1, 63, 52, 53, 54, 55, 56, 57,
        58, 59, 60, 61, -1, -1, -1, -1, -1, -1, -1, 0,  1,  2,  3,  4,  5,  6,
        7,  8,  9,  10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
        25, -1, -1, -1, -1, -1, -1, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36,
        37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1,
    };
    std::string out;
    int val = 0, valb = -8;
    for (unsigned char c : in) {
      if (lookup[c] == -1)
        break;
      val = (val << 6) + lookup[c];
      valb += 6;
      if (valb >= 0) {
        out.push_back((val >> valb) & 0xFF);
        valb -= 8;
      }
    }
    return out;
  }
  void save_pkg_db() {
    std::ofstream f(pkg_db);
    if (!f)
      return;
    for (auto &[n, p] : packages) {
      if (p.source == PackageSource::ARCH_BINARY) {
        std::string deps_str;
        for (auto &d : p.dependencies)
          deps_str += d + " ";
        if (!deps_str.empty())
          deps_str.pop_back();
        f << "ARCH|" << p.name << "|" << p.version << "|" << p.repo << "|"
          << p.filename << "|" << p.size << "|" << p.description << "|"
          << (p.deps_resolved ? "1" : "0") << "|" << deps_str << "\n";
      } else if (p.source == PackageSource::GALACTICA) {
        // Encode build_script as base64 so newlines/pipes don't break parsing
        std::string encoded_script = base64_encode(p.build_script);
        // Encode deps as space-separated
        std::string deps_str;
        for (auto &d : p.dependencies)
          deps_str += d + " ";
        if (!deps_str.empty())
          deps_str.pop_back();
        f << "GALACTICA|" << p.name << "|" << p.version << "|" << p.url << "|"
          << p.category << "|" << p.description << "|" << p.type << "|"
          << encoded_script << "|" << deps_str << "\n";
      }
    }
  }

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
        std::string n, v, r, fn, sz, d, dr, deps_str;
        std::getline(is, n, '|');
        std::getline(is, v, '|');
        std::getline(is, r, '|');
        std::getline(is, fn, '|');
        std::getline(is, sz, '|');
        std::getline(is, d, '|');
        std::getline(is, dr, '|');
        std::getline(is, deps_str, '|');
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
        if (!deps_str.empty()) {
          std::istringstream ds(deps_str);
          std::string dep;
          while (ds >> dep)
            p.dependencies.push_back(dep);
        }
        packages[n] = p;
      } else if (type == "GALACTICA") {
        std::string n, v, u, c, d, t, encoded_script, deps_str;
        std::getline(is, n, '|');
        std::getline(is, v, '|');
        std::getline(is, u, '|');
        std::getline(is, c, '|');
        std::getline(is, d, '|');
        std::getline(is, t, '|');
        std::getline(is, encoded_script, '|');
        std::getline(is, deps_str, '|');
        Package p;
        p.name = n;
        p.version = v;
        p.url = u;
        p.category = c;
        p.description = d;
        p.type = t;
        p.build_script = base64_decode(encoded_script);
        p.source = PackageSource::GALACTICA;
        if (!deps_str.empty()) {
          std::istringstream ds(deps_str);
          std::string dep;
          while (ds >> dep)
            p.dependencies.push_back(dep);
        }
        packages[n] = p;
      }
    }
  }

  std::string resolve_lib_to_pkg(const std::string &dep) {
    if (dep.find(".so") != std::string::npos) {
      std::string base = dep.substr(0, dep.find(".so"));
      if (packages.count(base))
        return base;
      if (base.substr(0, 3) == "lib") {
        std::string without_lib = base.substr(3);
        if (packages.count(without_lib))
          return without_lib;
      }
      dbg("Could not resolve library: " + dep);
    }
    return dep;
  }

  std::vector<std::string>
  resolve_dependencies(const std::string &pkg_name,
                       std::set<std::string> &resolved,
                       std::set<std::string> &visited) {
    std::vector<std::string> install_order;
    if (visited.count(pkg_name))
      return install_order;
    visited.insert(pkg_name);
    if (installed.count(pkg_name)) {
      resolved.insert(pkg_name);
      return install_order;
    }
    auto it = packages.find(pkg_name);
    if (it == packages.end()) {
      warn("Dependency not found in database: " + pkg_name);
      return install_order;
    }
    const Package &pkg = it->second;
    for (const auto &dep : pkg.dependencies) {
      std::string resolved_dep = resolve_lib_to_pkg(dep);
      if (!resolved.count(resolved_dep)) {
        auto dep_order = resolve_dependencies(resolved_dep, resolved, visited);
        install_order.insert(install_order.end(), dep_order.begin(),
                             dep_order.end());
      }
    }
    if (!resolved.count(pkg_name)) {
      install_order.push_back(pkg_name);
      resolved.insert(pkg_name);
    }
    return install_order;
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
      line.erase(0, line.find_first_not_of(" \t\r\n"));
      line.erase(line.find_last_not_of(" \t\r\n") + 1);
      if (line.empty() || line[0] == '#')
        continue;
      if (line[0] == '[' && line.back() == ']') {
        section = line.substr(1, line.length() - 2);
        continue;
      }
      // Script section: append raw lines directly
      if (section == "Script") {
        if (!p.build_script.empty())
          p.build_script += "\n";
        p.build_script += line;
        continue;
      }
      size_t eq = line.find('=');
      if (eq == std::string::npos)
        continue;
      std::string key = line.substr(0, eq);
      std::string value = line.substr(eq + 1);
      key.erase(key.find_last_not_of(" \t") + 1);
      value.erase(0, value.find_first_not_of(" \t"));
      if (value.length() >= 2 && value[0] == '"' && value.back() == '"')
        value = value.substr(1, value.length() - 2);
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
        else if (key == "type")
          p.type = value;
      } else if (section == "Dependencies") {
        if (key == "depends") {
          std::istringstream deps(value);
          std::string dep;
          while (deps >> dep)
            p.dependencies.push_back(dep);
        }
      } else if (section == "Build") {
        p.build_flags[key] = value;
      }
    }
    if (!p.name.empty() && !p.version.empty()) {
      packages[p.name] = p;
      dbg("Loaded Galactica package: " + p.name +
          (p.type.empty() ? "" : " [" + p.type + "]"));
      return true;
    }
    return false;
  }

  bool load_galactica_packages() {
    if (galactica_pkgs.empty()) {
      dbg("No Galactica packages in INDEX");
      return false;
    }
    int loaded = 0;
    for (const auto &pkg_path : galactica_pkgs)
      if (parse_galactica_pkg(pkg_path))
        loaded++;
    if (loaded > 0) {
      ok("Loaded " + std::to_string(loaded) + " Galactica packages");
      return true;
    }
    return false;
  }

  bool sync_arch() {
    status("Syncing Arch databases...");
    for (auto &mirror : ARCH_MIRRORS) {
      bool all_ok = true;
      for (auto &repo : ARCH_REPOS) {
        std::string url = mirror + "/" + repo + "/os/x86_64/" + repo + ".db";
        std::string file = db_cache_dir + "/" + repo + ".db";
        if (!dl_file(url, file)) {
          all_ok = false;
          break;
        }
        if (!parse_arch_db_with_deps(file, repo)) {
          all_ok = false;
          break;
        }
      }
      if (all_ok) {
        ok("Successfully synced from " + mirror);
        return true;
      }
      warn("Failed to sync from " + mirror + ", trying next...");
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
      f << n << " " << p.version << " " << src << " " << p.type << "\n";
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
      is >> p.name >> p.version >> src >> p.type;
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
      for (auto &m : ARCH_MIRRORS)
        if (dl_file(m + "/" + p.repo + "/os/x86_64/" + p.filename, cached))
          break;
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

  bool install_galactica(const Package &p_in) {
    Package p = p_in;

    // If the script is missing (old cache or db loaded without script),
    // re-fetch the pkg file from GalacticaRepository to recover it.
    if (p.build_script.empty()) {
      dbg("build_script empty for " + p.name + ", re-fetching pkg file...");
      bool refetched = false;
      for (const auto &pkg_path : galactica_pkgs) {
        // pkg_path looks like "core/airride.pkg" — name in filename
        std::string basename = fs::path(pkg_path).stem().string();
        if (basename == p.name) {
          Package fresh;
          // Temporarily put name so parse stores under right key
          if (parse_galactica_pkg(pkg_path)) {
            auto it = packages.find(p.name);
            if (it != packages.end() && !it->second.build_script.empty()) {
              p = it->second;
              refetched = true;
              dbg("Re-fetched build_script for " + p.name);
            }
          }
          break;
        }
      }
      if (!refetched) {
        // galactica_pkgs index may be empty (fresh load from db, no sync).
        // Try fetching the index first then retry.
        if (galactica_pkgs.empty()) {
          fetch_galactica();
          for (const auto &pkg_path : galactica_pkgs) {
            std::string basename = fs::path(pkg_path).stem().string();
            if (basename == p.name) {
              if (parse_galactica_pkg(pkg_path)) {
                auto it = packages.find(p.name);
                if (it != packages.end() && !it->second.build_script.empty()) {
                  p = it->second;
                  refetched = true;
                }
              }
              break;
            }
          }
        }
        if (!refetched) {
          err("Cannot install " + p.name + ": no install script available");
          return false;
        }
      }
    }

    std::cout << "Installing from source: " << PINK << p.name << RESET << " "
              << p.version << "\n";

    char cwd_buffer[PATH_MAX];
    if (getcwd(cwd_buffer, sizeof(cwd_buffer)) == nullptr) {
      err("Failed to get current directory");
      return false;
    }
    std::string old_cwd = cwd_buffer;
    std::string build_path = build_dir + "/" + p.name;

    try {
      if (!fs::exists(build_dir))
        fs::create_directories(build_dir);
      if (!fs::exists(build_path))
        fs::create_directory(build_path);
    } catch (const fs::filesystem_error &e) {
      err("Failed to create build directory: " + std::string(e.what()));
      return false;
    }

    if (chdir(build_path.c_str()) != 0) {
      err("Failed to change to build directory: " + build_path);
      return false;
    }

    if (!p.url.empty()) {
      status("Downloading source...");
      std::string src_filename;
      size_t last_slash = p.url.find_last_of('/');
      src_filename = (last_slash != std::string::npos)
                         ? p.url.substr(last_slash + 1)
                         : p.name + ".tar.gz";
      std::string src_file = build_path + "/" + src_filename;

      if (!dl_file(p.url, src_file)) {
        err("Failed to download source from: " + p.url);
        chdir(old_cwd.c_str());
        return false;
      }

      if (src_filename.find(".tar") != std::string::npos ||
          src_filename.find(".tgz") != std::string::npos) {
        status("Extracting...");
        std::string tar_cmd =
            fs::exists("/bin/tar") ? "/bin/tar" : "busybox tar";
        std::string extract_cmd;
        if (src_filename.ends_with(".tar.gz") || src_filename.ends_with(".tgz"))
          extract_cmd = tar_cmd + " -xzf " + src_file;
        else if (src_filename.ends_with(".tar.bz2"))
          extract_cmd = tar_cmd + " -xjf " + src_file;
        else if (src_filename.ends_with(".tar.xz"))
          extract_cmd = tar_cmd + " -xJf " + src_file;
        else
          extract_cmd = tar_cmd + " -xf " + src_file;

        if (exec(extract_cmd + " 2>/dev/null") != 0) {
          if (exec(tar_cmd + " -xf " + src_file + " 2>/dev/null") != 0) {
            err("Failed to extract source");
            chdir(old_cwd.c_str());
            return false;
          }
        }

        // Only cd into a subdir for source packages (e.g. kernel tarballs).
        // Binary release tarballs (airride, poyo, etc.) have files at root —
        // do NOT cd into a subdir or the binaries won't be in cwd.
        if (p.type != "kernel" && p.type != "binary") {
          std::vector<fs::path> subdirs;
          for (auto &e : fs::directory_iterator(build_path))
            if (e.is_directory())
              subdirs.push_back(e.path());
          if (subdirs.size() == 1)
            chdir(subdirs[0].c_str());
        }
      }
    }

    if (!p.build_script.empty()) {
      status("Running install script...");
      std::ofstream script("build.sh");
      if (!script.is_open()) {
        err("Failed to create install script");
        chdir(old_cwd.c_str());
        return false;
      }
      script << "#!/bin/sh\nset -e\n\n" << p.build_script << "\n";
      script.close();
      chmod("build.sh", 0755);
      int result = system("sh build.sh 2>&1");
      if (result != 0) {
        err("Install script failed with exit code: " +
            std::to_string(WEXITSTATUS(result)));
        chdir(old_cwd.c_str());
        return false;
      }
    }

    chdir(old_cwd.c_str());
    Package ip = p;
    ip.installed = true;
    installed[p.name] = ip;
    save_installed();
    ok("Installed " + p.name);
    return true;
  } // ── Kernel package installation
    // ────────────────────────────────────────────
  bool install_kernel(const Package &p) {
    std::cout << "Installing kernel: " << PINK << p.name << RESET << " "
              << p.version << "\n";

    if (geteuid() != 0) {
      err("Kernel installation requires root privileges");
      return false;
    }

    // Use the normal galactica source installer to download + run the script
    if (!install_galactica(p))
      return false;

    // Run depmod to regenerate module dependencies
    status("Running depmod...");
    exec("depmod " + p.version + " 2>/dev/null || depmod -a 2>/dev/null");

    // Regenerate initramfs if ginitrd is available
    if (access("/usr/sbin/ginitrd", X_OK) == 0) {
      status("Generating initramfs...");
      std::string initrd_path = "/boot/initramfs-" + p.version + ".img";
      int ret = exec("ginitrd -o " + initrd_path + " 2>&1");
      if (ret == 0)
        ok("Initramfs generated: " + initrd_path);
      else
        warn("ginitrd failed — you may need to generate initramfs manually");
    } else {
      warn("ginitrd not found — skipping initramfs generation");
    }

    // Update bootloader
    status("Updating GRUB...");
    if (exec("grub-mkconfig -o /boot/grub/grub.cfg 2>&1") == 0)
      ok("GRUB config updated");
    else
      warn("grub-mkconfig failed — update /boot/grub/grub.cfg manually");

    ok("Kernel " + p.version + " installed — reboot to use");
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

    // Kernel-specific uninstall
    if (p.type == "kernel") {
      if (geteuid() != 0) {
        err("Kernel removal requires root");
        return false;
      }
      warn("Removing kernel " + p.version);
      exec("rm -f /boot/vmlinuz-" + p.version + " /boot/initramfs-" +
           p.version + ".img 2>/dev/null");
      exec("rm -rf /lib/modules/" + p.version + " 2>/dev/null");
      exec("grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null");
      installed.erase(name);
      save_installed();
      ok("Kernel " + p.version + " removed");
      return true;
    }

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

  void upgrade() {
    banner();
    load_installed();
    if (packages.empty())
      load_pkg_db();
    std::vector<std::pair<Package, Package>> upgradeable;
    for (auto &[name, inst] : installed) {
      auto it = packages.find(name);
      if (it == packages.end())
        continue;
      if (it->second.version != inst.version)
        upgradeable.push_back({inst, it->second});
    }
    if (upgradeable.empty()) {
      ok("System is up to date");
      return;
    }
    std::cout << "\n"
              << CYAN << "Packages to upgrade (" << upgradeable.size()
              << "):" << RESET << "\n";
    for (auto &[old_pkg, new_pkg] : upgradeable) {
      std::cout << "  " << PINK << old_pkg.name << RESET << " " << YELLOW
                << old_pkg.version << RESET << " -> " << GREEN
                << new_pkg.version << RESET;
      if (new_pkg.type == "kernel")
        std::cout << " " << CYAN << "[kernel — reboot required]" << RESET;
      std::cout << "\n";
    }
    std::cout << "\nProceed? [Y/n]: ";
    std::string response;
    std::getline(std::cin, response);
    if (!response.empty() && response[0] != 'y' && response[0] != 'Y') {
      std::cout << "Upgrade cancelled.\n";
      return;
    }
    for (auto &[old_pkg, new_pkg] : upgradeable) {
      status("Upgrading " + old_pkg.name + "...");
      std::string mf = manifest_dir + "/" + old_pkg.name + ".manifest";
      if (fs::exists(mf)) {
        std::ifstream f(mf);
        std::string line;
        while (std::getline(f, line))
          if (!line.empty())
            fs::remove(line);
      }
      installed.erase(old_pkg.name);
      if (new_pkg.type == "kernel")
        install_kernel(new_pkg);
      else
        install_arch(new_pkg);
    }
    ok("Upgrade complete");
  }

  void sync() {
    banner();
    std::string cache_db_path = get_cache_dir() + "/db";
    std::error_code ec;
    if (fs::exists(cache_db_path, ec)) {
      std::cout << "Removing old cache database...\n";
      if (fs::remove_all(cache_db_path, ec))
        ok("Old cache removed");
      else
        warn("Failed to remove old cache: " + ec.message());
    }
    fetch_galactica();
    load_galactica_packages();
    sync_arch();
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
                  << (p.type == "kernel" ? CYAN " [kernel]" RESET : "")
                  << (installed.count(n) ? GREEN " [installed]" RESET : "")
                  << "\n";
      }
    }
  }

  bool install(const std::string &name) {
    load_installed();
    if (packages.empty())
      load_pkg_db();
    if (installed.count(name)) {
      warn(name + " already installed");
      return false;
    }
    auto it = packages.find(name);
    if (it == packages.end()) {
      err("Not found: " + name);
      return false;
    }
    const Package &pkg = it->second;
    if (pkg.source == PackageSource::GALACTICA) {
      // resolve deps first
      for (const auto &dep : pkg.dependencies) {
        if (!installed.count(dep)) {
          auto dep_it = packages.find(dep);
          if (dep_it != packages.end())
            install(dep);
          else
            warn("Dependency not found: " + dep);
        }
      }
      if (pkg.type == "kernel")
        return install_kernel(pkg);
      return install_galactica(pkg);
    } else if (pkg.source == PackageSource::ARCH_BINARY) {
      status("Resolving dependencies for " + name + "...");
      std::set<std::string> resolved, visited;
      std::vector<std::string> install_order =
          resolve_dependencies(name, resolved, visited);

      // install_order may be empty if pkg has no deps — add it directly
      if (install_order.empty()) {
        install_order.push_back(name);
      }

      std::cout << "\n"
                << CYAN << "Packages to install (" << install_order.size()
                << "):" << RESET << "\n";
      size_t total_size = 0;
      for (const auto &pkg_name : install_order) {
        auto pkg_it = packages.find(pkg_name);
        if (pkg_it != packages.end()) {
          std::cout << "  " << pkg_name << " " << YELLOW
                    << pkg_it->second.version << RESET << "\n";
          total_size += pkg_it->second.size;
        }
      }
      std::cout << "\n" << CYAN << "Total download size: " << RESET;
      if (total_size < 1024)
        std::cout << total_size << " B\n";
      else if (total_size < 1024 * 1024)
        std::cout << (total_size / 1024.0) << " KB\n";
      else
        std::cout << (total_size / (1024.0 * 1024.0)) << " MB\n";
      std::cout << "\nProceed? [Y/n]: ";
      std::string response;
      std::getline(std::cin, response);
      if (!response.empty() && response[0] != 'y' && response[0] != 'Y') {
        std::cout << "Installation cancelled.\n";
        return false;
      }
      for (const auto &pkg_name : install_order) {
        auto pkg_it = packages.find(pkg_name);
        if (pkg_it != packages.end())
          if (!install_arch(pkg_it->second)) {
            err("Failed to install " + pkg_name);
            return false;
          }
      }
      ok("Successfully installed " + name + " with " +
         std::to_string(install_order.size()) + " package(s)");
      return true;
    }
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
      std::string kt = p.type == "kernel" ? BLUE " [kernel]" RESET : "";
      std::cout << "  " << n << " " << p.version << " " << t << kt << "\n";
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
    std::cout << "  upgrade         Upgrade all installed packages\n";
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
  else if (cmd == "upgrade")
    dl.upgrade();
  else if (cmd == "modules")
    dl.list_mods();
  else {
    dl.usage(argv[0]);
    return 1;
  }
  return 0;
}
