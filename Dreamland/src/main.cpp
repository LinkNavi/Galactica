#include <algorithm>
#include <archive.h>
#include <archive_entry.h>
#include <cstdlib>
#include <curl/curl.h>
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

// Colors
#define PINK "\033[38;5;213m"
#define BLUE "\033[38;5;117m"
#define GREEN "\033[0;32m"
#define YELLOW "\033[1;33m"
#define RED "\033[0;31m"
#define CYAN "\033[0;36m"
#define RESET "\033[0m"

// Galactica repository (your own packages)
#define GALACTICA_REPO "LinkNavi/GalacticaRepository"
#define GALACTICA_RAW_URL                                                      \
  "https://raw.githubusercontent.com/" GALACTICA_REPO "/main/"

// Arch Linux mirrors (for dependencies)
const std::vector<std::string> ARCH_MIRRORS = {
    "https://mirror.rackspace.com/archlinux",
    "https://mirrors.kernel.org/archlinux", "https://geo.mirror.pkgbuild.com"};

const std::vector<std::string> ARCH_REPOS = {"core", "extra"};

enum class PackageSource {
  GALACTICA,   // Your custom packages (built from source)
  ARCH_BINARY, // Arch Linux binary packages (for deps)
  UNKNOWN
};

const std::vector<std::string> BASE_DEVEL_PACKAGES = {
    "gcc",        "gcc-libs", "binutils", "make",    "autoconf", "automake",
    "pkg-config", "bison",    "flex",     "grep",    "sed",      "gawk",
    "patch",      "libtool",  "m4",       "texinfo", "gettext"};

// Unified package structure
struct Package {
  std::string name;
  std::string version;
  std::string description;
  std::string url;
  std::string category;
  std::vector<std::string> dependencies;
  std::map<std::string, std::string> build_flags;
  std::string build_script;
  bool installed = false;
  bool deps_resolved = false; // Track if we've fetched .PKGINFO

  // Source info
  PackageSource source = PackageSource::UNKNOWN;
  std::string repo;     // For Arch packages
  std::string filename; // For Arch packages
  size_t size = 0;      // For Arch packages
};

// Callback functions for curl
static size_t write_callback(void *contents, size_t size, size_t nmemb,
                             std::string *userp) {
  userp->append((char *)contents, size * nmemb);
  return size * nmemb;
}

static size_t write_file_callback(void *contents, size_t size, size_t nmemb,
                                  FILE *fp) {
  return fwrite(contents, size, nmemb, fp);
}

class DreamlandHybrid {
private:
  std::string cache_dir;
  std::string pkg_db;
  std::string build_dir;
  std::string installed_db;
  std::string pkg_index;
  std::string pkg_cache_dir;
  std::string db_cache_dir;
  bool debug_mode = false;

  std::map<std::string, Package> packages; // All packages
  std::map<std::string, Package> installed;
  std::set<std::string>
      galactica_packages; // List of available Galactica packages
  std::set<std::string> installing;

  std::string get_home_dir() {
    const char *home = getenv("HOME");
    return home ? std::string(home) : "/tmp";
  }

  void init_directories() {
    std::string home = get_home_dir();

    const char *xdg_cache = getenv("XDG_CACHE_HOME");
    std::string base_cache =
        xdg_cache ? std::string(xdg_cache) : home + "/.cache";

    const char *xdg_data = getenv("XDG_DATA_HOME");
    std::string base_data =
        xdg_data ? std::string(xdg_data) : home + "/.local/share";

    cache_dir = base_cache + "/dreamland";
    build_dir = cache_dir + "/build";
    pkg_index = cache_dir + "/package_index.txt";
    pkg_cache_dir = cache_dir + "/packages";
    db_cache_dir = cache_dir + "/db";

    installed_db = base_data + "/dreamland/installed.db";
    pkg_db = base_data + "/dreamland/packages.db";

    // Check for debug mode
    const char *debug_env = getenv("DREAMLAND_DEBUG");
    if (debug_env && std::string(debug_env) == "1") {
      debug_mode = true;
    }

    try {
      fs::create_directories(cache_dir);
      fs::create_directories(build_dir);
      fs::create_directories(pkg_cache_dir);
      fs::create_directories(db_cache_dir);
      fs::create_directories(fs::path(installed_db).parent_path());
      fs::create_directories(fs::path(pkg_db).parent_path());
    } catch (const fs::filesystem_error &e) {
      print_error("Failed to create directories: " + std::string(e.what()));
      throw;
    }
  }

  void save_package_db() {
    std::ofstream file(pkg_db);
    if (!file.is_open()) {
      print_warning("Could not save package database");
      return;
    }

    for (const auto &[name, pkg] : packages) {
      if (pkg.source == PackageSource::ARCH_BINARY) {
        file << "ARCH|" << pkg.name << "|" << pkg.version << "|" << pkg.repo
             << "|" << pkg.filename << "|" << pkg.size << "|" << pkg.description
             << "|" << (pkg.deps_resolved ? "1" : "0");
        
        // Save dependencies if resolved
        if (pkg.deps_resolved && !pkg.dependencies.empty()) {
          file << "|";
          for (size_t i = 0; i < pkg.dependencies.size(); i++) {
            file << pkg.dependencies[i];
            if (i < pkg.dependencies.size() - 1) {
              file << ",";
            }
          }
        }
        file << "\n";
      }
    }

    file.close();
    print_debug("Saved package database");
  }

  void load_package_db() {
    std::ifstream file(pkg_db);
    if (!file.is_open()) {
      print_debug("No cached package database found");
      return;
    }

    std::string line;
    int count = 0;

    while (std::getline(file, line)) {
      std::istringstream iss(line);
      std::string type, name, version, repo, filename, size_str, desc, deps_resolved_str, deps_str;

      if (!std::getline(iss, type, '|'))
        continue;
      if (!std::getline(iss, name, '|'))
        continue;
      if (!std::getline(iss, version, '|'))
        continue;
      if (!std::getline(iss, repo, '|'))
        continue;
      if (!std::getline(iss, filename, '|'))
        continue;
      if (!std::getline(iss, size_str, '|'))
        continue;
      if (!std::getline(iss, desc, '|'))
        continue;
      if (!std::getline(iss, deps_resolved_str, '|'))
        continue;
      std::getline(iss, deps_str);

      if (type == "ARCH") {
        Package pkg;
        pkg.name = name;
        pkg.version = version;
        pkg.repo = repo;
        pkg.filename = filename;
        try {
          pkg.size = std::stoull(size_str);
        } catch (...) {
          pkg.size = 0;
        }
        pkg.description = desc;
        pkg.source = PackageSource::ARCH_BINARY;
        pkg.deps_resolved = (deps_resolved_str == "1");
        
        // Parse dependencies if they were saved
        if (!deps_str.empty()) {
          std::istringstream deps_stream(deps_str);
          std::string dep;
          while (std::getline(deps_stream, dep, ',')) {
            if (!dep.empty()) {
              pkg.dependencies.push_back(dep);
            }
          }
        }
        
        packages[name] = pkg;
        count++;
      }
    }

    file.close();
    print_debug("Loaded " + std::to_string(count) + " packages from cache");
  }

  void print_banner() {
    std::cout << PINK;
    std::cout << "    ★ ･ﾟ: *✧･ﾟ:* DREAMLAND *:･ﾟ✧*:･ﾟ★\n";
    std::cout << "      Galactica Package Manager\n";
    std::cout << "      Source-First Philosophy\n";
    std::cout << RESET << "\n";
  }

  void print_status(const std::string &msg) {
    std::cout << BLUE << "[★] " << RESET << msg << std::endl;
  }

  void print_success(const std::string &msg) {
    std::cout << GREEN << "[✓] " << RESET << msg << std::endl;
  }

  void print_error(const std::string &msg) {
    std::cerr << RED << "[✗] " << RESET << msg << std::endl;
  }

  void print_warning(const std::string &msg) {
    std::cout << YELLOW << "[!] " << RESET << msg << std::endl;
  }

  void print_debug(const std::string &msg) {
    if (debug_mode) {
      std::cout << "[DEBUG] " << msg << std::endl;
    }
  }

  bool download_url(const std::string &url, std::string &output) {
    CURL *curl = curl_easy_init();
    if (!curl)
      return false;

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &output);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Dreamland/2.1");
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);

    CURLcode res = curl_easy_perform(curl);
    long response_code;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
    curl_easy_cleanup(curl);

    return (res == CURLE_OK && response_code == 200);
  }

  bool download_to_file(const std::string &url, const std::string &filepath) {
    if (fs::exists(filepath) && fs::file_size(filepath) > 0) {
      print_debug("Using cached file: " + filepath);
      return true;
    }

    CURL *curl = curl_easy_init();
    if (!curl)
      return false;

    fs::create_directories(fs::path(filepath).parent_path());

    FILE *fp = fopen(filepath.c_str(), "wb");
    if (!fp) {
      curl_easy_cleanup(curl);
      return false;
    }

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_file_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, fp);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Dreamland/2.1");
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);

    CURLcode res = curl_easy_perform(curl);
    long response_code;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);

    fclose(fp);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK || response_code != 200) {
      fs::remove(filepath);
      return false;
    }

    return fs::exists(filepath) && fs::file_size(filepath) > 0;
  }

  int execute_command(const std::string &cmd) {
    print_debug("Executing: " + cmd);
    int status = system(cmd.c_str());
    return WEXITSTATUS(status);
  }

  // GALACTICA REPOSITORY

  bool fetch_galactica_index() {
    print_status("Fetching Galactica package index...");

    std::string index_url = GALACTICA_RAW_URL "INDEX";
    std::string index_content;

    if (!download_url(index_url, index_content)) {
      print_error("Failed to fetch Galactica index");
      return false;
    }

    std::ofstream index_file(pkg_index);
    if (!index_file.is_open())
      return false;

    index_file << index_content;
    index_file.close();

    galactica_packages.clear();
    std::istringstream iss(index_content);
    std::string line;

    while (std::getline(iss, line)) {
      line.erase(0, line.find_first_not_of(" \t\r\n"));
      line.erase(line.find_last_not_of(" \t\r\n") + 1);

      if (!line.empty() && line[0] != '#') {
        galactica_packages.insert(line);
      }
    }

    print_success("Found " + std::to_string(galactica_packages.size()) +
                  " Galactica packages");
    return true;
  }

  bool parse_galactica_package(const std::string &filepath, Package &pkg) {
    std::ifstream file(filepath);
    if (!file.is_open())
      return false;

    std::string line;
    std::string current_section;

    while (std::getline(file, line)) {
      line.erase(0, line.find_first_not_of(" \t\r\n"));
      line.erase(line.find_last_not_of(" \t\r\n") + 1);

      if (line.empty() || line[0] == '#')
        continue;

      if (line[0] == '[' && line[line.length() - 1] == ']') {
        current_section = line.substr(1, line.length() - 2);
        continue;
      }

      size_t eq_pos = line.find('=');
      if (eq_pos == std::string::npos) {
        if (current_section == "Script") {
          pkg.build_script += line + "\n";
        }
        continue;
      }

      std::string key = line.substr(0, eq_pos);
      std::string value = line.substr(eq_pos + 1);

      key.erase(key.find_last_not_of(" \t") + 1);
      value.erase(0, value.find_first_not_of(" \t"));

      if (value.length() >= 2 && value[0] == '"' &&
          value[value.length() - 1] == '"') {
        value = value.substr(1, value.length() - 2);
      }

      if (current_section == "Package") {
        if (key == "name")
          pkg.name = value;
        else if (key == "version")
          pkg.version = value;
        else if (key == "description")
          pkg.description = value;
        else if (key == "url")
          pkg.url = value;
        else if (key == "category")
          pkg.category = value;
      } else if (current_section == "Dependencies") {
        if (key == "depends") {
          std::istringstream iss(value);
          std::string dep;
          while (iss >> dep) {
            pkg.dependencies.push_back(dep);
          }
        }
      } else if (current_section == "Build") {
        pkg.build_flags[key] = value;
      }
    }

    if (!pkg.name.empty()) {
      pkg.source = PackageSource::GALACTICA;
      pkg.deps_resolved = true; // Galactica packages have deps in file
      return true;
    }
    return false;
  }

  std::string find_galactica_package(const std::string &pkg_name) {
    for (const auto &path : galactica_packages) {
      size_t last_slash = path.find_last_of('/');
      std::string filename = (last_slash != std::string::npos)
                                 ? path.substr(last_slash + 1)
                                 : path;

      size_t ext_pos = filename.find_last_of('.');
      std::string name = (ext_pos != std::string::npos)
                             ? filename.substr(0, ext_pos)
                             : filename;

      if (name == pkg_name) {
        return path;
      }
    }
    return "";
  }

  bool load_galactica_package(const std::string &pkg_name) {
    std::string pkg_path = find_galactica_package(pkg_name);
    if (pkg_path.empty()) {
      return false;
    }

    std::string pkg_url = GALACTICA_RAW_URL + pkg_path;
    std::string local_path = cache_dir + "/" + pkg_path;

    if (!fs::exists(local_path)) {
      fs::create_directories(fs::path(local_path).parent_path());
      std::string content;
      if (!download_url(pkg_url, content)) {
        return false;
      }
      std::ofstream out(local_path);
      if (!out.is_open())
        return false;
      out << content;
      out.close();
    }

    Package pkg;
    if (parse_galactica_package(local_path, pkg)) {
      packages[pkg.name] = pkg;
      print_debug("Loaded Galactica package: " + pkg.name);
      return true;
    }

    return false;
  }

  // ARCH REPOSITORY - Database parsing for package listing only
  bool parse_arch_db(const std::string &db_file, const std::string &repo) {
    print_status("Parsing Arch " + repo + " database (basic info only)...");

    std::string extract_dir = db_cache_dir + "/" + repo;
    fs::create_directories(extract_dir);

    std::string cmd =
        "tar -xzf " + db_file + " -C " + extract_dir + " 2>/dev/null";
    if (execute_command(cmd) != 0) {
      return false;
    }

    int count = 0;
    for (const auto &entry : fs::directory_iterator(extract_dir)) {
      if (!entry.is_directory())
        continue;

      std::string pkg_dir = entry.path();
      std::string desc_file = pkg_dir + "/desc";

      if (!fs::exists(desc_file))
        continue;

      Package pkg;
      pkg.source = PackageSource::ARCH_BINARY;
      pkg.repo = repo;
      pkg.deps_resolved = false; // Will resolve from .pkg.tar.zst later

      std::ifstream desc(desc_file);
      std::string line, section;

      while (std::getline(desc, line)) {
        if (line.empty())
          continue;

        if (line[0] == '%' && line[line.length() - 1] == '%') {
          section = line.substr(1, line.length() - 2);
          continue;
        }

        if (section == "NAME") {
          pkg.name = line;
        } else if (section == "VERSION") {
          pkg.version = line;
        } else if (section == "DESC") {
          if (pkg.description.empty()) {
            pkg.description = line;
          }
        } else if (section == "FILENAME") {
          pkg.filename = line;
        } else if (section == "CSIZE") {
          try {
            pkg.size = std::stoull(line);
          } catch (...) {
          }
        }
      }

      if (!pkg.name.empty() && !pkg.version.empty()) {
        if (packages.find(pkg.name) == packages.end()) {
          packages[pkg.name] = pkg;
          count++;
        }
      }
    }

    print_success("Parsed " + std::to_string(count) + " Arch packages from " +
                  repo);
    return count > 0;
  }

  bool sync_arch_databases() {
    print_status("Syncing Arch Linux databases (for package discovery)...");

    bool success = false;

    for (const auto &mirror : ARCH_MIRRORS) {
      bool mirror_ok = true;

      for (const auto &repo : ARCH_REPOS) {
        std::string db_url = mirror + "/" + repo + "/os/x86_64/" + repo + ".db";
        std::string db_file = db_cache_dir + "/" + repo + ".db";

        if (download_to_file(db_url, db_file)) {
          if (parse_arch_db(db_file, repo)) {
            success = true;
          } else {
            mirror_ok = false;
            break;
          }
        } else {
          mirror_ok = false;
          break;
        }
      }

      if (mirror_ok)
        break;
    }

    return success;
  }

  // Parse .PKGINFO from a .pkg.tar.zst file
  bool parse_pkginfo_from_archive(const std::string &pkg_file, Package &pkg) {
    print_debug("Reading .PKGINFO from " + pkg.name);
    
    struct archive *a;
    struct archive_entry *entry;
    
    a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    
    if (archive_read_open_filename(a, pkg_file.c_str(), 10240) != ARCHIVE_OK) {
      print_debug("Failed to open archive for .PKGINFO reading");
      archive_read_free(a);
      return false;
    }
    
    bool found_pkginfo = false;
    std::string pkginfo_content;
    
    // Find and read .PKGINFO file
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
      std::string pathname = archive_entry_pathname(entry);
      
      if (pathname == ".PKGINFO") {
        found_pkginfo = true;
        size_t size = archive_entry_size(entry);
        
        if (size > 0 && size < 1024 * 1024) { // Sanity check: < 1MB
          std::vector<char> buffer(size);
          ssize_t bytes_read = archive_read_data(a, buffer.data(), size);
          
          if (bytes_read > 0) {
            pkginfo_content = std::string(buffer.begin(), buffer.begin() + bytes_read);
          }
        }
        break;
      }
      
      archive_read_data_skip(a);
    }
    
    archive_read_close(a);
    archive_read_free(a);
    
    if (!found_pkginfo || pkginfo_content.empty()) {
      print_debug("No .PKGINFO found in package");
      return false;
    }
    
    // Parse .PKGINFO content
    std::istringstream iss(pkginfo_content);
    std::string line;
    std::vector<std::string> dependencies;
    
    while (std::getline(iss, line)) {
      // Skip comments and empty lines
      if (line.empty() || line[0] == '#')
        continue;
      
      // Parse key = value format
      size_t eq_pos = line.find('=');
      if (eq_pos == std::string::npos)
        continue;
      
      std::string key = line.substr(0, eq_pos);
      std::string value = line.substr(eq_pos + 1);
      
      // Trim whitespace
      key.erase(0, key.find_first_not_of(" \t"));
      key.erase(key.find_last_not_of(" \t") + 1);
      value.erase(0, value.find_first_not_of(" \t"));
      value.erase(value.find_last_not_of(" \t") + 1);
      
      if (key == "depend") {
        // Strip version constraints
        std::string dep = value;
        size_t op_pos = dep.find_first_of(">=<");
        if (op_pos != std::string::npos) {
          dep = dep.substr(0, op_pos);
        }
        dependencies.push_back(dep);
        print_debug("  Dependency: " + dep);
      }
    }
    
    // Update package dependencies
    pkg.dependencies = dependencies;
    pkg.deps_resolved = true;
    
    print_debug("Resolved " + std::to_string(dependencies.size()) + 
               " dependencies from .PKGINFO for " + pkg.name);
    
    return true;
  }

  // Download and parse .PKGINFO to get dependencies
  bool resolve_arch_package_deps(const std::string &pkg_name) {
    auto it = packages.find(pkg_name);
    if (it == packages.end()) {
      print_debug("Package not found: " + pkg_name);
      return false;
    }

    Package &pkg = it->second;

    // Already resolved?
    if (pkg.deps_resolved && !pkg.dependencies.empty()) {
      print_debug("Dependencies already resolved for " + pkg_name);
      return true;
    }

    // Skip if not an Arch package
    if (pkg.source != PackageSource::ARCH_BINARY) {
      return false;
    }

    print_debug("Resolving dependencies for " + pkg_name + " from .pkg.tar.zst...");

    std::string cached_pkg = pkg_cache_dir + "/" + pkg.filename;

    // Download if not cached
    if (!fs::exists(cached_pkg)) {
      print_status("Downloading " + pkg_name + " to read dependencies...");
      
      bool downloaded = false;
      for (const auto &mirror : ARCH_MIRRORS) {
        std::string pkg_url =
            mirror + "/" + pkg.repo + "/os/x86_64/" + pkg.filename;

        if (download_to_file(pkg_url, cached_pkg)) {
          downloaded = true;
          break;
        }
      }

      if (!downloaded) {
        print_warning("Failed to download package for dependency resolution");
        return false;
      }
    }

    // Parse .PKGINFO
    if (parse_pkginfo_from_archive(cached_pkg, pkg)) {
      // Update in packages map
      packages[pkg_name] = pkg;
      return true;
    }

    return false;
  }

  bool extract_zst_package(const std::string &pkg_file,
                           const std::string &dest) {
    print_status("Extracting binary package...");

    struct archive *a;
    struct archive *ext;
    struct archive_entry *entry;
    int r;

    a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    ext = archive_write_disk_new();
    archive_write_disk_set_options(
        ext, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_ACL |
                 ARCHIVE_EXTRACT_FFLAGS);

    if (archive_read_open_filename(a, pkg_file.c_str(), 10240) != ARCHIVE_OK) {
      archive_read_free(a);
      archive_write_free(ext);
      return false;
    }

    while (true) {
      r = archive_read_next_header(a, &entry);
      if (r == ARCHIVE_EOF)
        break;
      if (r != ARCHIVE_OK)
        break;

      std::string pathname = archive_entry_pathname(entry);
      if (pathname[0] == '.' &&
          (pathname.find(".PKGINFO") != std::string::npos ||
           pathname.find(".MTREE") != std::string::npos ||
           pathname.find(".BUILDINFO") != std::string::npos ||
           pathname.find(".INSTALL") != std::string::npos)) {
        continue;
      }

      std::string full_path = dest + "/" + pathname;
      archive_entry_set_pathname(entry, full_path.c_str());

      r = archive_write_header(ext, entry);
      if (r == ARCHIVE_OK) {
        const void *buff;
        size_t size;
        int64_t offset;

        while (true) {
          r = archive_read_data_block(a, &buff, &size, &offset);
          if (r == ARCHIVE_EOF)
            break;
          if (r != ARCHIVE_OK)
            break;

          if (archive_write_data_block(ext, buff, size, offset) != ARCHIVE_OK) {
            break;
          }
        }
      }
    }

    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);

    return true;
  }

  std::string get_url_extension(const std::string &url) {
    if (url.find(".tar.gz") != std::string::npos ||
        url.find(".tgz") != std::string::npos) {
      return ".tar.gz";
    }
    if (url.find(".tar.bz2") != std::string::npos) {
      return ".tar.bz2";
    }
    if (url.find(".tar.xz") != std::string::npos) {
      return ".tar.xz";
    }
    if (url.find(".zip") != std::string::npos) {
      return ".zip";
    }
    size_t pos = url.find_last_of('.');
    if (pos != std::string::npos) {
      return url.substr(pos);
    }
    return ".tar.gz";
  }

  bool download_source(const Package &pkg, const std::string &dest) {
    print_status("Downloading " + pkg.name + " source...");

    fs::create_directories(dest);

    if (pkg.url.find(".git") != std::string::npos) {
      std::string cmd = "git clone --depth 1 " + pkg.url + " " + dest + " 2>&1";
      if (execute_command(cmd) != 0) {
        print_error("Git clone failed");
        return false;
      }
      return true;
    }

    std::string ext = get_url_extension(pkg.url);
    std::string archive = "/tmp/" + pkg.name + "-" + pkg.version + ext;

    if (!download_to_file(pkg.url, archive)) {
      print_error("Failed to download source archive");
      return false;
    }

    if (!fs::exists(archive) || fs::file_size(archive) < 100) {
      print_error("Downloaded archive is empty or too small");
      return false;
    }

    print_status("Extracting " + pkg.name + "...");

    std::string cmd;
    if (ext == ".tar.gz" || ext == ".tgz") {
      cmd =
          "tar -xzf " + archive + " -C " + dest + " --strip-components=1 2>&1";
    } else if (ext == ".tar.bz2") {
      cmd =
          "tar -xjf " + archive + " -C " + dest + " --strip-components=1 2>&1";
    } else if (ext == ".tar.xz") {
      cmd =
          "tar -xJf " + archive + " -C " + dest + " --strip-components=1 2>&1";
    } else if (ext == ".zip") {
      cmd = "unzip -q -o " + archive + " -d " + dest + " 2>&1";
    } else {
      print_error("Unknown archive format: " + ext);
      return false;
    }

    if (execute_command(cmd) != 0) {
      print_error("Failed to extract archive");
      return false;
    }

    fs::remove(archive);

    bool has_files = false;
    for (const auto &entry : fs::directory_iterator(dest)) {
      has_files = true;
      break;
    }

    if (!has_files) {
      print_error("Extraction produced no files");
      return false;
    }

    print_success("Downloaded and extracted " + pkg.name);
    return true;
  }

  bool command_exists(const std::string &cmd) {
    std::string check = "command -v " + cmd + " >/dev/null 2>&1";
    return execute_command(check) == 0;
  }

  bool check_build_tools(const Package &pkg, const std::string &build_path) {
    std::vector<std::string> missing;

    if (!command_exists("gcc") && !command_exists("cc") &&
        !command_exists("clang")) {
      missing.push_back("gcc (C compiler)");
    }

    bool needs_cmake = false;
    bool needs_make = false;
    bool needs_meson = false;
    bool needs_ninja = false;
    bool needs_autoconf = false;
    bool needs_automake = false;

    if (!pkg.build_script.empty()) {
      if (pkg.build_script.find("cmake") != std::string::npos)
        needs_cmake = true;
      if (pkg.build_script.find("make") != std::string::npos)
        needs_make = true;
      if (pkg.build_script.find("meson") != std::string::npos)
        needs_meson = true;
      if (pkg.build_script.find("ninja") != std::string::npos)
        needs_ninja = true;
      if (pkg.build_script.find("autoconf") != std::string::npos)
        needs_autoconf = true;
      if (pkg.build_script.find("automake") != std::string::npos)
        needs_automake = true;
    }

    if (fs::exists(build_path + "/CMakeLists.txt"))
      needs_cmake = true;
    if (fs::exists(build_path + "/Makefile") ||
        fs::exists(build_path + "/Makefile.in"))
      needs_make = true;
    if (fs::exists(build_path + "/configure"))
      needs_make = true;
    if (fs::exists(build_path + "/configure.ac") ||
        fs::exists(build_path + "/configure.in")) {
      needs_autoconf = true;
      needs_automake = true;
      needs_make = true;
    }
    if (fs::exists(build_path + "/meson.build")) {
      needs_meson = true;
      needs_ninja = true;
    }

    if (needs_cmake && !command_exists("cmake"))
      missing.push_back("cmake");
    if (needs_make && !command_exists("make"))
      missing.push_back("make");
    if (needs_meson && !command_exists("meson"))
      missing.push_back("meson");
    if (needs_ninja && !command_exists("ninja"))
      missing.push_back("ninja");
    if (needs_autoconf && !command_exists("autoconf"))
      missing.push_back("autoconf");
    if (needs_automake && !command_exists("automake"))
      missing.push_back("automake");

    if (!missing.empty()) {
      print_error("Missing required build tools:");
      for (const auto &tool : missing) {
        std::cout << "  • " << RED << tool << RESET << "\n";
      }
      std::cout << "\nInstall with: " << YELLOW << "dreamland base-devel"
                << RESET << "\n";
      std::cout << "Or manually: " << YELLOW << "dreamland install --arch ";
      for (const auto &tool : missing) {
        std::cout << tool << " ";
      }
      std::cout << RESET << "\n";
      return false;
    }

    return true;
  }
  
  bool build_package(const Package &pkg, const std::string &build_path) {
    print_status("Building " + pkg.name + "...");

    if (!check_build_tools(pkg, build_path)) {
      return false;
    }

    std::string script_path = build_path + "/dreamland_build.sh";
    std::ofstream script(script_path);

    if (!script.is_open()) {
      print_error("Cannot create build script");
      return false;
    }

    script << "#!/bin/sh\n";
    script << "set -e\n\n";
    script << "cd \"" << build_path << "\"\n\n";

    for (const auto &[key, value] : pkg.build_flags) {
      script << "export " << key << "=\"" << value << "\"\n";
    }
    script << "\n";

    script << "export PREFIX=\"/usr\"\n";
    script << "export DESTDIR=\"\"\n";
    script << "NPROC=$(nproc 2>/dev/null || echo 2)\n";
    script << "\n";

    if (pkg.build_script.empty()) {
      script << "if [ -f configure ]; then\n";
      script << "    ./configure --prefix=/usr\n";
      script << "    make -j$NPROC\n";
      script << "    make install\n";
      script << "elif [ -f CMakeLists.txt ]; then\n";
      script << "    mkdir -p build && cd build\n";
      script << "    cmake .. -DCMAKE_INSTALL_PREFIX=/usr "
                "-DCMAKE_BUILD_TYPE=Release\n";
      script << "    make -j$NPROC\n";
      script << "    make install\n";
      script << "elif [ -f meson.build ]; then\n";
      script << "    meson setup build --prefix=/usr\n";
      script << "    ninja -C build\n";
      script << "    ninja -C build install\n";
      script << "elif [ -f Makefile ]; then\n";
      script << "    make -j$NPROC\n";
      script << "    make install PREFIX=/usr\n";
      script << "else\n";
      script << "    echo 'No build system detected'\n";
      script << "    exit 1\n";
      script << "fi\n";
    } else {
      script << pkg.build_script;
    }

    script.close();

    try {
      fs::permissions(script_path,
                      fs::perms::owner_exec | fs::perms::owner_read |
                          fs::perms::owner_write,
                      fs::perm_options::add);
    } catch (const fs::filesystem_error &e) {
      print_error("Cannot set permissions");
      return false;
    }

    std::string log_file = build_path + "/build.log";
    std::string cmd = "/bin/sh " + script_path + " > " + log_file + " 2>&1";

    int result = execute_command(cmd);

    if (result == 0) {
      print_success("Built " + pkg.name + " successfully");
      return true;
    } else {
      print_error("Build failed for " + pkg.name);
      print_warning("Build log: " + log_file);
      std::string cat_cmd = "tail -50 " + log_file;
      execute_command(cat_cmd);
      return false;
    }
  }

  // INSTALLATION

  bool install_from_galactica(const Package &pkg) {
    print_banner();
    std::cout << "Installing: " << PINK << pkg.name << RESET << " "
              << pkg.version << " " << CYAN << "[building from source]" << RESET
              << "\n";
    std::cout << pkg.description << "\n\n";

    std::string build_path = build_dir + "/" + pkg.name;

    try {
      fs::remove_all(build_path);
      fs::create_directories(build_path);
    } catch (const fs::filesystem_error &e) {
      print_error("Cannot create build directory");
      return false;
    }

    if (!download_source(pkg, build_path)) {
      print_error("Failed to download source");
      return false;
    }

    if (!build_package(pkg, build_path)) {
      return false;
    }

    Package installed_pkg = pkg;
    installed_pkg.installed = true;
    installed[pkg.name] = installed_pkg;
    save_installed();

    try {
      fs::remove_all(build_path);
    } catch (const fs::filesystem_error &e) {
      print_warning("Could not clean build directory");
    }

    print_success("Successfully built and installed " + pkg.name + "!");
    return true;
  }

  bool install_from_arch(const Package &pkg) {
    print_banner();
    std::cout << "Installing: " << PINK << pkg.name << RESET << " "
              << pkg.version << " " << YELLOW << "[binary from Arch]" << RESET
              << "\n";
    std::cout << pkg.description << "\n\n";

    std::string cached_pkg = pkg_cache_dir + "/" + pkg.filename;

    if (!fs::exists(cached_pkg)) {
      print_status("Downloading from Arch mirrors...");

      bool downloaded = false;
      for (const auto &mirror : ARCH_MIRRORS) {
        std::string pkg_url =
            mirror + "/" + pkg.repo + "/os/x86_64/" + pkg.filename;

        if (download_to_file(pkg_url, cached_pkg)) {
          downloaded = true;
          break;
        }
      }

      if (!downloaded) {
        print_error("Failed to download package");
        return false;
      }
    } else {
      print_success("Using cached package");
    }

    if (!extract_zst_package(cached_pkg, "")) {
      print_error("Failed to extract package");
      return false;
    }

    Package installed_pkg = pkg;
    installed_pkg.installed = true;
    installed[pkg.name] = installed_pkg;
    save_installed();

    print_success("Successfully installed " + pkg.name + " from Arch!");
    return true;
  }

  void save_installed() {
    fs::create_directories(fs::path(installed_db).parent_path());

    std::ofstream file(installed_db);
    if (!file.is_open())
      return;

    for (const auto &[name, pkg] : installed) {
      file << name << " " << pkg.version << " "
           << (pkg.source == PackageSource::GALACTICA ? "galactica" : "arch")
           << "\n";
    }
  }

  void load_installed() {
    if (!fs::exists(installed_db))
      return;

    std::ifstream file(installed_db);
    if (!file.is_open())
      return;

    std::string line;
    while (std::getline(file, line)) {
      if (line.empty())
        continue;

      std::istringstream iss(line);
      Package pkg;
      std::string source_str;
      iss >> pkg.name >> pkg.version >> source_str;

      pkg.installed = true;
      pkg.source = (source_str == "galactica") ? PackageSource::GALACTICA
                                               : PackageSource::ARCH_BINARY;
      installed[pkg.name] = pkg;
    }
  }

  std::vector<std::string> resolve_dependencies(const std::string &pkg_name) {
    std::map<std::string, std::vector<std::string>> dep_graph;
    std::set<std::string> all_packages;

    // Build complete dependency graph using BFS
    std::queue<std::string> to_process;
    to_process.push(pkg_name);

    while (!to_process.empty()) {
      std::string current = to_process.front();
      to_process.pop();

      if (all_packages.count(current))
        continue; // Already processed
      if (installed.count(current))
        continue; // Already installed

      all_packages.insert(current);

      // Load package if not already loaded
      auto it = packages.find(current);
      if (it == packages.end()) {
        load_galactica_package(current);
        it = packages.find(current);
      }

      if (it == packages.end()) {
        print_debug("Dependency not found, skipping: " + current);
        continue;
      }

      // Resolve dependencies from .PKGINFO if it's an Arch package
      if (it->second.source == PackageSource::ARCH_BINARY && 
          !it->second.deps_resolved) {
        resolve_arch_package_deps(current);
        it = packages.find(current); // Refresh iterator
      }

      // Extract and queue all dependencies
      std::vector<std::string> deps;
      for (const auto &dep_raw : it->second.dependencies) {
        std::string dep = dep_raw;
        // Strip version constraints
        size_t op_pos = dep.find_first_of(">=<");
        if (op_pos != std::string::npos) {
          dep = dep.substr(0, op_pos);
        }

        deps.push_back(dep);
        to_process.push(dep); // Queue for processing
      }

      dep_graph[current] = deps;
    }

    // Topological sort using DFS
    std::vector<std::string> result;
    std::set<std::string> visited;
    std::set<std::string> temp_mark;

    std::function<bool(const std::string &)> visit =
        [&](const std::string &node) -> bool {
      if (visited.count(node))
        return true;
      if (temp_mark.count(node)) {
        print_error("Circular dependency: " + node);
        return false;
      }

      temp_mark.insert(node);

      if (dep_graph.count(node)) {
        for (const auto &dep : dep_graph[node]) {
          if (!visit(dep))
            return false;
        }
      }

      temp_mark.erase(node);
      visited.insert(node);
      result.push_back(node);
      return true;
    };

    // Visit all packages
    for (const auto &pkg : all_packages) {
      if (!visit(pkg))
        return {};
    }

    return result;
  }

public:
  DreamlandHybrid() {
    init_directories();
    curl_global_init(CURL_GLOBAL_DEFAULT);
  }

  ~DreamlandHybrid() { curl_global_cleanup(); }

  void sync() {
    print_banner();
    print_status("Syncing repositories...");
    std::cout << "Cache: " << cache_dir << "\n\n";

    if (!fetch_galactica_index()) {
      print_error("Failed to sync Galactica repository");
      return;
    }

    if (!sync_arch_databases()) {
      print_error("Failed to sync Arch repositories");
      return;
    }

    save_package_db();
    load_installed();

    int galactica_count = galactica_packages.size();
    int arch_count = 0;
    for (const auto &[name, pkg] : packages) {
      if (pkg.source == PackageSource::ARCH_BINARY)
        arch_count++;
    }

    print_success("Sync complete!");
    std::cout << "  " << PINK << galactica_packages.size() << RESET
              << " Galactica packages (source-first)\n";
    std::cout << "  " << YELLOW << arch_count << RESET
              << " Arch packages (binary fallback)\n";
    std::cout << "\n";
    std::cout << CYAN << "Note:" << RESET << " Dependencies resolved from .pkg.tar.zst files\n";
    std::cout << "  • Accurate and authoritative\n";
    std::cout << "  • Downloads packages as needed\n";
    std::cout << "  • Full control over your system ✨\n";
  }

  void search(const std::string &query) {
    if (packages.empty() && galactica_packages.empty()) {
      print_status("Loading package database...");
      load_package_db();

      std::ifstream index_file(pkg_index);
      if (index_file.is_open()) {
        std::string line;
        while (std::getline(index_file, line)) {
          line.erase(0, line.find_first_not_of(" \t\r\n"));
          line.erase(line.find_last_not_of(" \t\r\n") + 1);
          if (!line.empty() && line[0] != '#') {
            galactica_packages.insert(line);
          }
        }
      }
    }

    load_installed();

    if (galactica_packages.empty() && packages.empty()) {
      print_warning("Package database is empty. Run 'dreamland sync' first.");
      return;
    }

    print_status("Searching for: " + query);
    std::cout << "\n";

    bool found = false;

    // Search Galactica first
    for (const auto &pkg_path : galactica_packages) {
      size_t last_slash = pkg_path.find_last_of('/');
      std::string filename = (last_slash != std::string::npos)
                                 ? pkg_path.substr(last_slash + 1)
                                 : pkg_path;

      size_t ext_pos = filename.find_last_of('.');
      std::string name = (ext_pos != std::string::npos)
                             ? filename.substr(0, ext_pos)
                             : filename;

      if (name.find(query) != std::string::npos) {
        if (load_galactica_package(name)) {
          auto &pkg = packages[name];

          bool is_installed = installed.find(name) != installed.end();
          std::string status = is_installed ? GREEN " [installed]" RESET : "";

          std::cout << PINK << name << RESET << " " << pkg.version << status
                    << CYAN " [source]" RESET << "\n";
          std::cout << "  " << pkg.description << "\n";
          found = true;
        }
      }
    }

    // Show Arch packages only if not in Galactica
    for (const auto &[name, pkg] : packages) {
      if (pkg.source != PackageSource::ARCH_BINARY)
        continue;

      if (find_galactica_package(name) != "")
        continue;

      if (name.find(query) != std::string::npos ||
          pkg.description.find(query) != std::string::npos) {

        bool is_installed = installed.find(name) != installed.end();
        std::string status = is_installed ? GREEN " [installed]" RESET : "";

        std::cout << PINK << name << RESET << " " << pkg.version << status
                  << YELLOW " [fallback]" RESET << "\n";
        std::cout << "  " << pkg.description << "\n";
        found = true;
      }
    }

    if (!found) {
      print_warning("No packages found matching: " + query);
    }
  }
  
  void install_base_devel() {
    print_banner();
    if (packages.empty() && galactica_packages.empty()) {
      print_status("Loading package database...");
      load_package_db();

      std::ifstream index_file(pkg_index);
      if (index_file.is_open()) {
        std::string line;
        while (std::getline(index_file, line)) {
          line.erase(0, line.find_first_not_of(" \t\r\n"));
          line.erase(line.find_last_not_of(" \t\r\n") + 1);
          if (!line.empty() && line[0] != '#') {
            galactica_packages.insert(line);
          }
        }
      }
    }
    std::cout << "Installing base development packages...\n\n";

    if (packages.empty()) {
      print_warning("Package database empty. Run 'dreamland sync' first.");
      return;
    }

    std::vector<std::string> to_install_list;

    for (const auto &pkg_name : BASE_DEVEL_PACKAGES) {
      // Check if already installed
      if (installed.count(pkg_name)) {
        continue;
      }

      // Check if in Arch repos
      if (packages.count(pkg_name) &&
          packages[pkg_name].source == PackageSource::ARCH_BINARY) {
        to_install_list.push_back(pkg_name);
      }
    }

    if (to_install_list.empty()) {
      print_success("All base-devel packages already installed!");
      return;
    }

    std::cout << "\nPackages to install (" << to_install_list.size() << "):\n";
    for (const auto &name : to_install_list) {
      std::cout << "  • " << name << "\n";
    }

    std::cout << "\nNote: Dependencies will be resolved from .pkg.tar.zst files\n";
    std::cout << "\nContinue? (y/n) [y]: ";
    std::string confirm;
    std::getline(std::cin, confirm);
    if (!confirm.empty() && confirm != "y" && confirm != "Y") {
      return;
    }

    // Install all packages (resolve_dependencies will handle dep resolution)
    for (const auto &name : to_install_list) {
      if (!install_package(name, true)) {
        print_error("Failed to install " + name);
        return;
      }
    }

    print_success("base-devel installation complete!");
  }

  bool install_package(const std::string &pkg_name, bool force_arch = false) {
    load_installed();

    if (packages.empty() && galactica_packages.empty()) {
      print_status("Loading package database...");
      load_package_db();

      std::ifstream index_file(pkg_index);
      if (index_file.is_open()) {
        std::string line;
        while (std::getline(index_file, line)) {
          line.erase(0, line.find_first_not_of(" \t\r\n"));
          line.erase(line.find_last_not_of(" \t\r\n") + 1);
          if (!line.empty() && line[0] != '#') {
            galactica_packages.insert(line);
          }
        }
      }
    }

    if (packages.empty() && galactica_packages.empty()) {
      print_warning("Package database is empty. Run 'dreamland sync' first.");
      return false;
    }

    if (installed.find(pkg_name) != installed.end()) {
      print_warning(pkg_name + " is already installed...installing anyways "
                               "(there is no uninstall command yet)");
    }

    Package *pkg_ptr = nullptr;

    if (force_arch) {
      auto it = packages.find(pkg_name);
      if (it != packages.end() &&
          it->second.source == PackageSource::ARCH_BINARY) {
        pkg_ptr = &it->second;
        std::cout << YELLOW << "→ Using Arch binary (--arch flag)" << RESET
                  << "\n\n";
      } else {
        print_error("Package not found in Arch repositories: " + pkg_name);
        return false;
      }
    } else {
      // Try Galactica FIRST (source-first philosophy)
      if (load_galactica_package(pkg_name)) {
        auto it = packages.find(pkg_name);
        if (it != packages.end()) {
          pkg_ptr = &it->second;
          std::cout << CYAN << "→ Building from source (Galactica)" << RESET
                    << "\n\n";
        }
      }

      // Fall back to Arch if not in Galactica
      if (!pkg_ptr) {
        auto it = packages.find(pkg_name);
        if (it != packages.end() &&
            it->second.source == PackageSource::ARCH_BINARY) {
          pkg_ptr = &it->second;
          std::cout << YELLOW
                    << "→ Falling back to Arch binary (not in Galactica)"
                    << RESET << "\n\n";
        }
      }

      if (!pkg_ptr) {
        print_error("Package not found: " + pkg_name);
        return false;
      }
    }

    print_status("Resolving dependencies for " + pkg_name + " (from .pkg.tar.zst)...");
    std::vector<std::string> install_order = resolve_dependencies(pkg_name);

    if (install_order.empty()) {
      print_error("Failed to resolve dependencies");
      return false;
    }

    // Show installation plan
    std::cout << "\n";
    print_status("Installation plan:");
    int to_install = 0;
    size_t total_size = 0;

    for (const auto &name : install_order) {
      if (!installed.count(name)) {
        // Make sure package is loaded
        if (packages.find(name) == packages.end()) {
          load_galactica_package(name);
        }

        if (packages.find(name) == packages.end()) {
          print_warning("Package disappeared: " + name);
          continue;
        }

        auto &pkg = packages[name];

        std::string source_label;
        if (force_arch || pkg.source == PackageSource::ARCH_BINARY) {
          source_label = YELLOW "[binary]" RESET;
          total_size += pkg.size;
        } else {
          source_label = CYAN "[source]" RESET;
        }

        std::cout << "  " << (++to_install) << ". " << PINK << name << RESET
                  << " " << source_label;

        if (pkg.source == PackageSource::ARCH_BINARY && pkg.size > 0) {
          std::cout << " (" << (pkg.size / 1024 / 1024) << " MB)";
        }
        
        if (pkg.deps_resolved && !pkg.dependencies.empty()) {
          std::cout << " [" << pkg.dependencies.size() << " deps]";
        }
        std::cout << "\n";
      }
    }

    if (to_install == 0) {
      print_success("All dependencies already satisfied!");
      return true;
    }

    std::cout << "\n";
    std::cout << "Total packages: " << to_install << "\n";
    if (total_size > 0) {
      std::cout << "Download size: " << (total_size / 1024 / 1024)
                << " MB (binaries)\n";
    }
    std::cout << "\n";

    std::string confirm;
    std::cout << "Continue? (y/n) [y]: ";
    std::getline(std::cin, confirm);

    if (!confirm.empty() && confirm != "y" && confirm != "Y") {
      print_warning("Installation cancelled");
      return false;
    }

    // Install packages in dependency order
    for (const auto &name : install_order) {
      if (installed.count(name))
        continue;

      std::cout << "\n";
      std::cout << BLUE << "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" << RESET
                << "\n";

      if (packages.find(name) == packages.end()) {
        load_galactica_package(name);
      }

      if (packages.find(name) == packages.end()) {
        print_error("Package not found: " + name);
        return false;
      }

      const auto &pkg = packages[name];
      bool success = false;

      // Use Arch binary if forced OR if package is from Arch
      if (force_arch || pkg.source == PackageSource::ARCH_BINARY) {
        success = install_from_arch(pkg);
      } else if (pkg.source == PackageSource::GALACTICA) {
        success = install_from_galactica(pkg);
      }

      if (!success) {
        print_error("Failed to install " + name);
        return false;
      }
      
      // Save updated package database with resolved deps
      save_package_db();
    }

    std::cout << "\n";
    std::cout << GREEN << "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" << RESET
              << "\n";
    std::cout << GREEN << "Installation Complete!" << RESET << "\n";
    std::cout << GREEN << "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" << RESET
              << "\n\n";

    return true;
  }
  
  void list_installed() {
    print_banner();
    load_installed();

    if (installed.empty()) {
      print_warning("No packages installed");
      return;
    }

    std::cout << "Installed packages (" << installed.size() << "):\n\n";

    int source_count = 0;
    int binary_count = 0;

    for (const auto &[name, pkg] : installed) {
      std::string source_tag = (pkg.source == PackageSource::GALACTICA)
                                   ? CYAN " [source]" RESET
                                   : YELLOW " [binary]" RESET;

      std::cout << PINK << name << RESET << " " << pkg.version << source_tag
                << "\n";

      if (pkg.source == PackageSource::GALACTICA)
        source_count++;
      else
        binary_count++;
    }

    std::cout << "\n";
    std::cout << "Built from source: " << source_count << "\n";
    std::cout << "Binary (from Arch): " << binary_count << "\n";
  }

  void clean() {
    print_banner();
    print_status("Cleaning caches...");

    size_t pkg_cache_size = 0;
    size_t build_cache_size = 0;
    int pkg_count = 0;
    int build_count = 0;

    if (fs::exists(pkg_cache_dir)) {
      for (const auto &entry :
           fs::recursive_directory_iterator(pkg_cache_dir)) {
        if (fs::is_regular_file(entry)) {
          pkg_cache_size += fs::file_size(entry);
          pkg_count++;
        }
      }
    }

    if (fs::exists(build_dir)) {
      for (const auto &entry : fs::recursive_directory_iterator(build_dir)) {
        if (fs::is_regular_file(entry)) {
          build_cache_size += fs::file_size(entry);
          build_count++;
        }
      }
    }

    std::cout << "Binary cache: " << (pkg_cache_size / 1024.0 / 1024.0)
              << " MB (" << pkg_count << " files)\n";
    std::cout << "Build cache: " << (build_cache_size / 1024.0 / 1024.0)
              << " MB (" << build_count << " files)\n\n";

    std::string confirm;
    std::cout << "Remove all caches? (y/n): ";
    std::getline(std::cin, confirm);

    if (confirm == "y" || confirm == "Y") {
      try {
        for (const auto &entry : fs::directory_iterator(pkg_cache_dir)) {
          fs::remove_all(entry);
        }
        for (const auto &entry : fs::directory_iterator(build_dir)) {
          fs::remove_all(entry);
        }
        print_success("Caches cleaned!");
      } catch (const fs::filesystem_error &e) {
        print_error("Failed to clean caches: " + std::string(e.what()));
      }
    }
  }

  void show_deps(const std::string &pkg_name, bool recursive = false) {
    if (packages.empty() && galactica_packages.empty()) {
      print_status("Loading package database...");
      load_package_db();

      std::ifstream index_file(pkg_index);
      if (index_file.is_open()) {
        std::string line;
        while (std::getline(index_file, line)) {
          line.erase(0, line.find_first_not_of(" \t\r\n"));
          line.erase(line.find_last_not_of(" \t\r\n") + 1);
          if (!line.empty() && line[0] != '#') {
            galactica_packages.insert(line);
          }
        }
      }
    }

    load_installed();

    if (packages.empty() && galactica_packages.empty()) {
      print_warning("Package database is empty. Run 'dreamland sync' first.");
      return;
    }

    // Try to find package
    Package *pkg_ptr = nullptr;

    // Try Galactica first
    if (load_galactica_package(pkg_name)) {
      auto it = packages.find(pkg_name);
      if (it != packages.end()) {
        pkg_ptr = &it->second;
      }
    }

    // Try Arch
    if (!pkg_ptr) {
      auto it = packages.find(pkg_name);
      if (it != packages.end() &&
          it->second.source == PackageSource::ARCH_BINARY) {
        pkg_ptr = &it->second;
      }
    }

    if (!pkg_ptr) {
      print_error("Package not found: " + pkg_name);
      return;
    }

    print_banner();
    std::cout << "Package: " << PINK << pkg_ptr->name << RESET << " "
              << pkg_ptr->version;

    if (pkg_ptr->source == PackageSource::GALACTICA) {
      std::cout << CYAN " [source]" RESET << "\n";
    } else {
      std::cout << YELLOW " [binary]" RESET << "\n";
    }

    std::cout << pkg_ptr->description << "\n\n";

    // Resolve dependencies if Arch package
    if (pkg_ptr->source == PackageSource::ARCH_BINARY &&
        !pkg_ptr->deps_resolved) {
      print_status("Resolving dependencies from .pkg.tar.zst...");
      resolve_arch_package_deps(pkg_name);
      pkg_ptr = &packages[pkg_name]; // Refresh pointer
    }

    if (!recursive) {
      // Simple list of direct dependencies
      if (pkg_ptr->dependencies.empty()) {
        std::cout << CYAN << "No dependencies" << RESET << "\n";
      } else {
        std::cout << CYAN << "Direct dependencies (" 
                  << pkg_ptr->dependencies.size() << "):" << RESET << "\n";
        for (const auto &dep : pkg_ptr->dependencies) {
          bool is_installed = installed.find(dep) != installed.end();
          std::string status = is_installed ? GREEN " [installed]" RESET : "";
          std::cout << "  • " << dep << status << "\n";
        }
      }
    } else {
      // Recursive dependency tree
      std::cout << CYAN << "Full dependency tree:" << RESET << "\n\n";

      std::set<std::string> all_deps;
      std::map<std::string, std::vector<std::string>> dep_tree;
      std::queue<std::string> to_process;

      to_process.push(pkg_name);
      all_deps.insert(pkg_name);

      // Build dependency tree
      while (!to_process.empty()) {
        std::string current = to_process.front();
        to_process.pop();

        auto it = packages.find(current);
        if (it == packages.end()) {
          if (!load_galactica_package(current)) {
            continue;
          }
          it = packages.find(current);
        }

        if (it == packages.end())
          continue;

        // Resolve if needed
        if (it->second.source == PackageSource::ARCH_BINARY &&
            !it->second.deps_resolved) {
          resolve_arch_package_deps(current);
          it = packages.find(current);
        }

        std::vector<std::string> deps;
        for (const auto &dep : it->second.dependencies) {
          std::string clean_dep = dep;
          size_t op_pos = clean_dep.find_first_of(">=<");
          if (op_pos != std::string::npos) {
            clean_dep = clean_dep.substr(0, op_pos);
          }
          deps.push_back(clean_dep);

          if (all_deps.find(clean_dep) == all_deps.end()) {
            all_deps.insert(clean_dep);
            to_process.push(clean_dep);
          }
        }

        dep_tree[current] = deps;
      }

      // Print tree recursively
      std::set<std::string> printed;
      std::function<void(const std::string &, int, bool)> print_tree =
          [&](const std::string &node, int depth, bool is_last) {
            if (printed.count(node)) {
              for (int i = 0; i < depth; i++)
                std::cout << "  ";
              std::cout << (is_last ? "└─ " : "├─ ");
              std::cout << node << YELLOW " (already shown)" RESET << "\n";
              return;
            }

            printed.insert(node);

            for (int i = 0; i < depth; i++)
              std::cout << "  ";

            if (depth > 0) {
              std::cout << (is_last ? "└─ " : "├─ ");
            }

            bool is_installed = installed.find(node) != installed.end();
            std::string status = is_installed ? GREEN " [installed]" RESET : "";

            std::cout << node << status;

            // Show package source
            auto it = packages.find(node);
            if (it != packages.end()) {
              if (it->second.source == PackageSource::GALACTICA) {
                std::cout << CYAN " [source]" RESET;
              } else if (it->second.source == PackageSource::ARCH_BINARY) {
                std::cout << YELLOW " [binary]" RESET;
              }
            }
            std::cout << "\n";

            if (dep_tree.count(node)) {
              const auto &deps = dep_tree[node];
              for (size_t i = 0; i < deps.size(); i++) {
                print_tree(deps[i], depth + 1, i == deps.size() - 1);
              }
            }
          };

      print_tree(pkg_name, 0, true);

      std::cout << "\n";
      std::cout << "Total dependencies: " << (all_deps.size() - 1) << "\n";

      // Count installed
      int installed_count = 0;
      for (const auto &dep : all_deps) {
        if (dep != pkg_name && installed.count(dep)) {
          installed_count++;
        }
      }

      if (installed_count > 0) {
        std::cout << "Already installed: " << installed_count << "\n";
      }
    }
  }

  void show_usage(const std::string &prog) {
    print_banner();
    std::cout << "Usage: " << prog << " <command> [options]\n\n";
    std::cout << "Commands:\n";
    std::cout << "  sync                     Sync package databases\n";
    std::cout << "  install [opts] <package> Install a package\n";
    std::cout << "  search <query>           Search for packages\n";
    std::cout << "  deps <package> [opts]    Show package dependencies\n";
    std::cout << "  list                     List installed packages\n";
    std::cout << "  clean                    Clean caches\n";
    std::cout << "  base-devel               Install base development tools\n";
    std::cout << "\nInstall Options:\n";
    std::cout
        << "  --arch                   Force Arch binary (skip source build)\n";
    std::cout << "\nDeps Options:\n";
    std::cout << "  --recursive, -r          Show full dependency tree\n";
    std::cout << "\nExamples:\n";
    std::cout << "  " << prog << " sync\n";
    std::cout << "  " << prog << " search editor\n";
    std::cout << "  " << prog << " deps neovim\n";
    std::cout << "  " << prog << " deps neovim --recursive\n";
    std::cout << "  " << prog
              << " install vim          # Builds from source (Galactica)\n";
    std::cout << "  " << prog
              << " install --arch vim   # Forces Arch binary (faster)\n";
    std::cout << "  " << prog
              << " install htop         # From Arch (not in Galactica)\n";
    std::cout << "\nPhilosophy:\n";
    std::cout << "  " << CYAN << "• Source-first:" << RESET
              << " Build from Galactica by default\n";
    std::cout << "  " << YELLOW << "• Binary fallback:" << RESET
              << " Use --arch for speed/convenience\n";
    std::cout << "  " << CYAN << "• .PKGINFO deps:" << RESET
              << " Accurate dependencies from package files\n";
    std::cout << "  • Full control over your system\n";
    std::cout << "  • Transparency and reproducibility\n";
    std::cout << "\nConfiguration:\n";
    std::cout << "  Your repo:  " GALACTICA_REPO "\n";
    std::cout << "  Cache:      " << cache_dir << "\n";
    std::cout << "  Data:       "
              << fs::path(installed_db).parent_path().string() << "\n";
    std::cout << "\nDebug Mode:\n";
    std::cout << "  export DREAMLAND_DEBUG=1\n";
  }
};

int main(int argc, char *argv[]) {
  try {
    DreamlandHybrid dl;

    if (argc < 2) {
      dl.show_usage(argv[0]);
      return 1;
    }

    std::string command = argv[1];

    if (command == "sync") {
      dl.sync();
    } else if (command == "search" && argc >= 3) {
      dl.search(argv[2]);
    } else if (command == "deps" && argc >= 3) {
      bool recursive = false;
      std::string pkg_name;

      for (int i = 2; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--recursive" || arg == "-r") {
          recursive = true;
        } else {
          pkg_name = arg;
        }
      }

      if (pkg_name.empty()) {
        std::cerr << RED << "Error: No package name specified" << RESET << "\n";
        dl.show_usage(argv[0]);
        return 1;
      }

      dl.show_deps(pkg_name, recursive);
    } else if (command == "install" && argc >= 3) {
      bool force_arch = false;
      std::string pkg_name;

      for (int i = 2; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--arch") {
          force_arch = true;
        } else {
          pkg_name = arg;
        }
      }

      if (pkg_name.empty()) {
        std::cerr << RED << "Error: No package name specified" << RESET << "\n";
        dl.show_usage(argv[0]);
        return 1;
      }

      return dl.install_package(pkg_name, force_arch) ? 0 : 1;
    } else if (command == "list") {
      dl.list_installed();
    } else if (command == "clean") {
      dl.clean();
    } else if (command == "base-devel") {
      dl.install_base_devel();
    } else {
      dl.show_usage(argv[0]);
      return 1;
    }

    return 0;

  } catch (const std::exception &e) {
    std::cerr << RED << "[✗] Fatal error: " << e.what() << RESET << std::endl;
    return 1;
  }
}
