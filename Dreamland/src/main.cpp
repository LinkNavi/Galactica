#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <queue>
#include <filesystem>
#include <cstdlib>
#include <unistd.h>
#include <sys/wait.h>
#include <curl/curl.h>
#include <functional>
namespace fs = std::filesystem;

// Colors
#define PINK "\033[38;5;213m"
#define BLUE "\033[38;5;117m"
#define GREEN "\033[0;32m"
#define YELLOW "\033[1;33m"
#define RED "\033[0;31m"
#define RESET "\033[0m"

// GitHub repository settings
#define GITHUB_REPO "LinkNavi/GalacticaRepository"
#define GITHUB_RAW_URL "https://raw.githubusercontent.com/" GITHUB_REPO "/main/"
#define GITHUB_API_URL "https://api.github.com/repos/" GITHUB_REPO "/contents/"

// Package structure
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
};

// Callback for curl to write data to string
static size_t write_callback(void* contents, size_t size, size_t nmemb, std::string* userp) {
    userp->append((char*)contents, size * nmemb);
    return size * nmemb;
}

// Callback for curl to write data to file
static size_t write_file_callback(void* contents, size_t size, size_t nmemb, FILE* fp) {
    return fwrite(contents, size, nmemb, fp);
}

class Dreamland {
private:
    std::string cache_dir;
    std::string pkg_db;
    std::string build_dir;
    std::string installed_db;
    std::string pkg_index;
    
    std::map<std::string, Package> packages;
    std::map<std::string, Package> installed;
    std::set<std::string> available_packages;
    
    // Track packages being installed to detect circular dependencies
    std::set<std::string> installing;

    // Get user's home directory
    std::string get_home_dir() {
        const char* home = getenv("HOME");
        if (home) {
            return std::string(home);
        }
        return "/tmp";
    }

    // Initialize directory paths based on XDG standards
    void init_directories() {
        std::string home = get_home_dir();
        
        const char* xdg_cache = getenv("XDG_CACHE_HOME");
        std::string base_cache = xdg_cache ? std::string(xdg_cache) : home + "/.cache";
        
        const char* xdg_data = getenv("XDG_DATA_HOME");
        std::string base_data = xdg_data ? std::string(xdg_data) : home + "/.local/share";
        
        cache_dir = base_cache + "/dreamland";
        build_dir = cache_dir + "/build";
        pkg_index = cache_dir + "/package_index.txt";
        
        installed_db = base_data + "/dreamland/installed.db";
        pkg_db = base_data + "/dreamland/packages.db";
        
        try {
            fs::create_directories(cache_dir);
            fs::create_directories(build_dir);
            fs::create_directories(fs::path(installed_db).parent_path());
            fs::create_directories(fs::path(pkg_db).parent_path());
        } catch (const fs::filesystem_error& e) {
            print_error("Failed to create directories: " + std::string(e.what()));
            throw;
        }
    }

    void print_banner() {
        std::cout << PINK;
        std::cout << "    ★ ･ﾟ: *✧･ﾟ:* DREAMLAND *:･ﾟ✧*:･ﾟ★\n";
        std::cout << "      Galactica Package Manager\n";
        std::cout << "           Built from Source\n";
        std::cout << RESET << "\n";
    }

    void print_status(const std::string& msg) {
        std::cout << BLUE << "[★] " << RESET << msg << std::endl;
    }

    void print_success(const std::string& msg) {
        std::cout << GREEN << "[✓] " << RESET << msg << std::endl;
    }

    void print_error(const std::string& msg) {
        std::cerr << RED << "[✗] " << RESET << msg << std::endl;
    }

    void print_warning(const std::string& msg) {
        std::cout << YELLOW << "[!] " << RESET << msg << std::endl;
    }

    void print_debug(const std::string& msg) {
        // Uncomment for debugging
        // std::cout << "[DEBUG] " << msg << std::endl;
    }

    // Download content from URL using curl
    bool download_url(const std::string& url, std::string& output) {
        CURL* curl = curl_easy_init();
        if (!curl) {
            print_error("Failed to initialize curl");
            return false;
        }

        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &output);
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "Dreamland/1.0");
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 60L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
        
        CURLcode res = curl_easy_perform(curl);
        long response_code;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
        curl_easy_cleanup(curl);

        if (res != CURLE_OK) {
            print_error("Download failed: " + std::string(curl_easy_strerror(res)));
            return false;
        }

        if (response_code != 200) {
            print_error("HTTP error: " + std::to_string(response_code));
            return false;
        }

        return true;
    }

    // Download file from URL directly to file (for large files)
    bool download_to_file(const std::string& url, const std::string& filepath) {
        CURL* curl = curl_easy_init();
        if (!curl) {
            print_error("Failed to initialize curl");
            return false;
        }

        fs::create_directories(fs::path(filepath).parent_path());

        FILE* fp = fopen(filepath.c_str(), "wb");
        if (!fp) {
            print_error("Cannot open file for writing: " + filepath);
            curl_easy_cleanup(curl);
            return false;
        }

        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_file_callback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, fp);
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "Dreamland/1.0");
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);  // 5 min for large files
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
        
        // Progress indicator
        curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
        
        CURLcode res = curl_easy_perform(curl);
        long response_code;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
        
        fclose(fp);
        curl_easy_cleanup(curl);

        if (res != CURLE_OK) {
            print_error("Download failed: " + std::string(curl_easy_strerror(res)));
            fs::remove(filepath);
            return false;
        }

        if (response_code != 200) {
            print_error("HTTP error: " + std::to_string(response_code));
            fs::remove(filepath);
            return false;
        }

        // Verify file was created and has content
        if (!fs::exists(filepath) || fs::file_size(filepath) == 0) {
            print_error("Downloaded file is empty or missing");
            return false;
        }

        return true;
    }

    // Download file from URL to file (string version for small files)
    bool download_file(const std::string& url, const std::string& filepath) {
        std::string content;
        if (!download_url(url, content)) {
            return false;
        }

        fs::create_directories(fs::path(filepath).parent_path());

        std::ofstream file(filepath);
        if (!file.is_open()) {
            print_error("Cannot open file for writing: " + filepath);
            return false;
        }

        file << content;
        file.close();
        
        if (!fs::exists(filepath)) {
            print_error("File was not created: " + filepath);
            return false;
        }
        
        print_debug("Saved to: " + filepath);
        return true;
    }

    // Fetch package index from GitHub
    bool fetch_package_index() {
        print_status("Fetching package index from GitHub...");
        
        std::string index_url = GITHUB_RAW_URL "INDEX";
        std::string index_content;
        
        if (!download_url(index_url, index_content)) {
            print_error("Failed to fetch package index from: " + index_url);
            print_warning("Check your internet connection and repository URL");
            return false;
        }

        if (index_content.empty()) {
            print_error("Package index is empty");
            return false;
        }

        std::ofstream index_file(pkg_index);
        if (!index_file.is_open()) {
            print_error("Cannot write to: " + pkg_index);
            print_warning("Check permissions for: " + cache_dir);
            return false;
        }
        
        index_file << index_content;
        index_file.close();
        
        if (!fs::exists(pkg_index) || fs::file_size(pkg_index) == 0) {
            print_error("Failed to save package index to: " + pkg_index);
            return false;
        }
        
        print_debug("Package index saved to: " + pkg_index);

        // Parse package list
        available_packages.clear();
        std::istringstream iss(index_content);
        std::string line;
        int line_count = 0;
        
        while (std::getline(iss, line)) {
            line.erase(0, line.find_first_not_of(" \t\r\n"));
            line.erase(line.find_last_not_of(" \t\r\n") + 1);
            
            if (!line.empty() && line[0] != '#') {
                available_packages.insert(line);
                line_count++;
                print_debug("Added package: " + line);
            }
        }

        if (line_count == 0) {
            print_error("No packages found in index");
            return false;
        }

        print_success("Found " + std::to_string(available_packages.size()) + " packages");
        return true;
    }

    // Load local package index
    void load_package_index() {
        if (!fs::exists(pkg_index)) {
            print_debug("Package index not found: " + pkg_index);
            return;
        }

        std::ifstream file(pkg_index);
        if (!file.is_open()) {
            print_warning("Cannot read package index: " + pkg_index);
            return;
        }
        
        std::string line;
        int count = 0;
        
        while (std::getline(file, line)) {
            line.erase(0, line.find_first_not_of(" \t\r\n"));
            line.erase(line.find_last_not_of(" \t\r\n") + 1);
            
            if (!line.empty() && line[0] != '#') {
                available_packages.insert(line);
                count++;
            }
        }
        
        print_debug("Loaded " + std::to_string(count) + " packages from index");
    }

    // Download a specific .pkg file from GitHub
    bool download_package_definition(const std::string& pkg_path) {
        std::string pkg_url = GITHUB_RAW_URL + pkg_path;
        std::string local_path = cache_dir + "/" + pkg_path;
        
        try {
            fs::create_directories(fs::path(local_path).parent_path());
        } catch (const fs::filesystem_error& e) {
            print_error("Cannot create directory: " + std::string(e.what()));
            return false;
        }
        
        print_status("Downloading package definition...");
        print_debug("From: " + pkg_url);
        print_debug("To: " + local_path);
        
        if (!download_file(pkg_url, local_path)) {
            print_error("Failed to download: " + pkg_path);
            return false;
        }

        return true;
    }

    // Parse a package definition file
    bool parse_package(const std::string& filepath, Package& pkg) {
        std::ifstream file(filepath);
        if (!file.is_open()) {
            print_error("Cannot open package file: " + filepath);
            return false;
        }

        std::string line;
        std::string current_section;
        int line_num = 0;

        while (std::getline(file, line)) {
            line_num++;
            
            line.erase(0, line.find_first_not_of(" \t\r\n"));
            line.erase(line.find_last_not_of(" \t\r\n") + 1);
            
            if (line.empty() || line[0] == '#') continue;
            
            if (line[0] == '[' && line[line.length()-1] == ']') {
                current_section = line.substr(1, line.length()-2);
                print_debug("Parsing section: " + current_section);
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
            
            key.erase(0, key.find_first_not_of(" \t"));
            key.erase(key.find_last_not_of(" \t") + 1);
            value.erase(0, value.find_first_not_of(" \t"));
            value.erase(value.find_last_not_of(" \t") + 1);
            
            if (value.length() >= 2 && value[0] == '"' && value[value.length()-1] == '"') {
                value = value.substr(1, value.length()-2);
            }
            
            if (current_section == "Package") {
                if (key == "name") pkg.name = value;
                else if (key == "version") pkg.version = value;
                else if (key == "description") pkg.description = value;
                else if (key == "url") pkg.url = value;
                else if (key == "category") pkg.category = value;
            }
            else if (current_section == "Dependencies") {
                if (key == "depends") {
                    std::istringstream iss(value);
                    std::string dep;
                    while (iss >> dep) {
                        pkg.dependencies.push_back(dep);
                    }
                }
            }
            else if (current_section == "Build") {
                pkg.build_flags[key] = value;
            }
            else if (current_section == "Script") {
                pkg.build_script += line + "\n";
            }
        }

        if (pkg.name.empty()) {
            print_error("Package name not found in: " + filepath);
            return false;
        }
        
        print_debug("Parsed package: " + pkg.name + " " + pkg.version);
        return true;
    }

    // Find package path in index
    std::string find_package_path(const std::string& pkg_name) {
        for (const auto& path : available_packages) {
            size_t last_slash = path.find_last_of('/');
            std::string filename = (last_slash != std::string::npos) 
                ? path.substr(last_slash + 1) 
                : path;
            
            size_t ext_pos = filename.find_last_of('.');
            std::string name = (ext_pos != std::string::npos) 
                ? filename.substr(0, ext_pos) 
                : filename;
            
            if (name == pkg_name) {
                print_debug("Found package at: " + path);
                return path;
            }
        }
        
        print_debug("Package not found in index: " + pkg_name);
        return "";
    }

  

    // Save installed packages database
    void save_installed() {
        fs::create_directories(fs::path(installed_db).parent_path());
        
        std::ofstream file(installed_db);
        if (!file.is_open()) {
            print_error("Cannot write to installed database: " + installed_db);
            return;
        }
        
        for (const auto& [name, pkg] : installed) {
            file << name << " " << pkg.version << "\n";
        }
        
        file.close();
        print_debug("Saved installed database: " + installed_db);
    }

    // Execute a shell command
    int execute_command(const std::string& cmd) {
        print_debug("Executing: " + cmd);
        int status = system(cmd.c_str());
        return WEXITSTATUS(status);
    }

    // Get file extension from URL
    std::string get_url_extension(const std::string& url) {
        // Handle URLs like .tar.gz, .tar.bz2, .tar.xz
        if (url.find(".tar.gz") != std::string::npos || url.find(".tgz") != std::string::npos) {
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
        // Default
        size_t pos = url.find_last_of('.');
        if (pos != std::string::npos) {
            return url.substr(pos);
        }
        return ".tar.gz";
    }

    // Download source code using libcurl (not wget/curl CLI)
    bool download_source(const Package& pkg, const std::string& dest) {
        print_status("Downloading " + pkg.name + " source...");
        
        // Create destination directory
        fs::create_directories(dest);
        
        if (pkg.url.find(".git") != std::string::npos) {
            // Git clone
            std::string cmd = "git clone --depth 1 " + pkg.url + " " + dest + " 2>&1";
            if (execute_command(cmd) != 0) {
                print_error("Git clone failed");
                return false;
            }
            return true;
        }
        
        // Download archive using libcurl
        std::string ext = get_url_extension(pkg.url);
        std::string archive = "/tmp/" + pkg.name + "-" + pkg.version + ext;
        
        print_debug("Downloading: " + pkg.url);
        print_debug("To: " + archive);
        
        if (!download_to_file(pkg.url, archive)) {
            print_error("Failed to download source archive");
            return false;
        }
        
        // Verify download
        if (!fs::exists(archive) || fs::file_size(archive) < 100) {
            print_error("Downloaded archive is empty or too small");
            return false;
        }
        
        print_status("Extracting " + pkg.name + "...");
        
        // Extract based on extension
        std::string cmd;
        if (ext == ".tar.gz" || ext == ".tgz") {
            cmd = "tar -xzf " + archive + " -C " + dest + " --strip-components=1 2>&1";
        } else if (ext == ".tar.bz2") {
            cmd = "tar -xjf " + archive + " -C " + dest + " --strip-components=1 2>&1";
        } else if (ext == ".tar.xz") {
            cmd = "tar -xJf " + archive + " -C " + dest + " --strip-components=1 2>&1";
        } else if (ext == ".zip") {
            cmd = "unzip -q -o " + archive + " -d " + dest + " 2>&1";
            // Handle single top-level directory in zip
            // TODO: strip if needed
        } else {
            print_error("Unknown archive format: " + ext);
            return false;
        }
        
        if (execute_command(cmd) != 0) {
            print_error("Failed to extract archive");
            print_warning("Archive: " + archive);
            return false;
        }
        
        // Cleanup archive
        fs::remove(archive);
        
        // Verify extraction
        bool has_files = false;
        for (const auto& entry : fs::directory_iterator(dest)) {
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

    // Check if a command exists
    bool command_exists(const std::string& cmd) {
        std::string check = "command -v " + cmd + " >/dev/null 2>&1";
        return execute_command(check) == 0;
    }

    // Check for required build tools
    bool check_build_tools(const Package& pkg, const std::string& build_path) {
        std::vector<std::string> missing;
        
        // Always need a C compiler
        if (!command_exists("gcc") && !command_exists("cc") && !command_exists("clang")) {
            missing.push_back("gcc (C compiler)");
        }
        
        // Check what build system the package uses
        bool needs_cmake = false;
        bool needs_make = false;
        bool needs_meson = false;
        bool needs_ninja = false;
        bool needs_cargo = false;
        
        // Check from build script
        if (!pkg.build_script.empty()) {
            if (pkg.build_script.find("cmake") != std::string::npos) needs_cmake = true;
            if (pkg.build_script.find("make") != std::string::npos) needs_make = true;
            if (pkg.build_script.find("meson") != std::string::npos) needs_meson = true;
            if (pkg.build_script.find("ninja") != std::string::npos) needs_ninja = true;
            if (pkg.build_script.find("cargo") != std::string::npos) needs_cargo = true;
        }
        
        // Check from files in build directory
        if (fs::exists(build_path + "/CMakeLists.txt")) needs_cmake = true;
        if (fs::exists(build_path + "/Makefile")) needs_make = true;
        if (fs::exists(build_path + "/configure")) needs_make = true;
        if (fs::exists(build_path + "/meson.build")) { needs_meson = true; needs_ninja = true; }
        if (fs::exists(build_path + "/Cargo.toml")) needs_cargo = true;
        
        // Check if tools are installed
        if (needs_cmake && !command_exists("cmake")) {
            missing.push_back("cmake");
        }
        if (needs_make && !command_exists("make")) {
            missing.push_back("make");
        }
        if (needs_meson && !command_exists("meson")) {
            missing.push_back("meson");
        }
        if (needs_ninja && !command_exists("ninja")) {
            missing.push_back("ninja");
        }
        if (needs_cargo && !command_exists("cargo")) {
            missing.push_back("cargo (Rust)");
        }
        
        if (!missing.empty()) {
            print_error("Missing required build tools:");
            for (const auto& tool : missing) {
                std::cout << "  • " << RED << tool << RESET << "\n";
            }
            std::cout << "\n";
            print_warning("Install build tools first. You need a toolchain with:");
            std::cout << "  • C/C++ compiler (gcc, g++)\n";
            std::cout << "  • make\n";
            std::cout << "  • cmake (for most packages)\n";
            std::cout << "\nOn the host, add these to your rootfs, or install a\n";
            std::cout << "bootstrap toolchain package.\n";
            return false;
        }
        
        return true;
    }

    // Build package from source
    bool build_package(const Package& pkg, const std::string& build_path) {
        print_status("Building " + pkg.name + "...");
        
        // Check for required build tools BEFORE attempting build
        if (!check_build_tools(pkg, build_path)) {
            return false;
        }
        
        std::string script_path = build_path + "/dreamland_build.sh";
        std::ofstream script(script_path);
        
        if (!script.is_open()) {
            print_error("Cannot create build script: " + script_path);
            return false;
        }
        
        // Use /bin/sh instead of bash (more portable)
        script << "#!/bin/sh\n";
        script << "set -e\n\n";
        script << "cd \"" << build_path << "\"\n\n";
        
        // Export build flags
        for (const auto& [key, value] : pkg.build_flags) {
            script << "export " << key << "=\"" << value << "\"\n";
        }
        script << "\n";
        
        // Set standard build variables
        script << "# Standard build environment\n";
        script << "export PREFIX=\"/usr\"\n";
        script << "export DESTDIR=\"\"\n";
        script << "NPROC=$(nproc 2>/dev/null || echo 2)\n";
        script << "\n";
        
        if (pkg.build_script.empty()) {
            // Default build process
            script << "# Default build process\n";
            script << "if [ -f configure ]; then\n";
            script << "    ./configure --prefix=/usr\n";
            script << "    make -j$NPROC\n";
            script << "    make install\n";
            script << "elif [ -f CMakeLists.txt ]; then\n";
            script << "    mkdir -p build && cd build\n";
            script << "    cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release\n";
            script << "    make -j$NPROC\n";
            script << "    make install\n";
            script << "elif [ -f meson.build ]; then\n";
            script << "    meson setup build --prefix=/usr\n";
            script << "    ninja -C build\n";
            script << "    ninja -C build install\n";
            script << "elif [ -f Makefile ]; then\n";
            script << "    make -j$NPROC\n";
            script << "    make install PREFIX=/usr\n";
            script << "elif [ -f setup.py ]; then\n";
            script << "    python3 setup.py install --prefix=/usr\n";
            script << "elif [ -f Cargo.toml ]; then\n";
            script << "    cargo build --release\n";
            script << "    cargo install --path . --root /usr\n";
            script << "else\n";
            script << "    echo 'No build system detected'\n";
            script << "    ls -la\n";
            script << "    exit 1\n";
            script << "fi\n";
        } else {
            script << pkg.build_script;
        }
        
        script.close();
        
        try {
            fs::permissions(script_path, 
                fs::perms::owner_exec | fs::perms::owner_read | fs::perms::owner_write,
                fs::perm_options::add);
        } catch (const fs::filesystem_error& e) {
            print_error("Cannot set permissions: " + std::string(e.what()));
            return false;
        }
        
        // Run with /bin/sh, capture exit code properly
        std::string log_file = build_path + "/build.log";
        std::string cmd = "/bin/sh " + script_path + " > " + log_file + " 2>&1";
        
        int result = execute_command(cmd);
        
        // Show build output
        std::string cat_cmd = "cat " + log_file;
        execute_command(cat_cmd);
        
        if (result == 0) {
            print_success("Built " + pkg.name + " successfully");
            return true;
        } else {
            print_error("Build failed for " + pkg.name + " (exit code: " + std::to_string(result) + ")");
            print_warning("Build log: " + log_file);
            return false;
        }
    }

    // Resolve dependency tree using topological sort
    std::vector<std::string> resolve_dependencies(const std::string& pkg_name) {
        std::vector<std::string> install_order;
        std::set<std::string> visited;
        std::set<std::string> temp_mark;
        
        std::function<bool(const std::string&)> visit = [&](const std::string& name) -> bool {
            // Already visited - skip
            if (visited.count(name)) {
                return true;
            }
            
            // Circular dependency detection
            if (temp_mark.count(name)) {
                print_error("Circular dependency detected: " + name);
                return false;
            }
            
            // Already installed - skip
            if (installed.count(name)) {
                print_debug(name + " already installed, skipping");
                return true;
            }
            
            temp_mark.insert(name);
            
            // Load package info if not cached
            if (packages.find(name) == packages.end()) {
                std::string pkg_path = find_package_path(name);
                if (pkg_path.empty()) {
                    print_error("Package not found: " + name);
                    return false;
                }
                
                if (!download_package_definition(pkg_path)) {
                    return false;
                }
                
                std::string local_pkg = cache_dir + "/" + pkg_path;
                Package pkg;
                if (!parse_package(local_pkg, pkg)) {
                    return false;
                }
                
                packages[name] = pkg;
            }
            
            // Visit dependencies first
            const Package& pkg = packages[name];
            for (const auto& dep : pkg.dependencies) {
                if (!dep.empty() && !visit(dep)) {
                    return false;
                }
            }
            
            temp_mark.erase(name);
            visited.insert(name);
            install_order.push_back(name);
            
            return true;
        };
        
        if (!visit(pkg_name)) {
            return {};
        }
        
        return install_order;
    }

    // Install a single package (assumes deps already installed)
    bool install_package_internal(const std::string& pkg_name) {
        const Package& pkg = packages[pkg_name];
        
        print_banner();
        std::cout << "Installing: " << PINK << pkg.name << RESET << " " << pkg.version << "\n";
        std::cout << pkg.description << "\n\n";
        
        // Create build directory
        std::string build_path = build_dir + "/" + pkg_name;
        try {
            fs::remove_all(build_path);  // Clean previous attempts
            fs::create_directories(build_path);
        } catch (const fs::filesystem_error& e) {
            print_error("Cannot create build directory: " + std::string(e.what()));
            return false;
        }
        
        // Download source
        if (!download_source(pkg, build_path)) {
            print_error("Failed to download source");
            return false;
        }
        
        // Build package
        if (!build_package(pkg, build_path)) {
            return false;
        }
        
        // Mark as installed
        Package installed_pkg = pkg;
        installed_pkg.installed = true;
        installed[pkg_name] = installed_pkg;
        save_installed();
        
        // Cleanup build directory
        try {
            fs::remove_all(build_path);
        } catch (const fs::filesystem_error& e) {
            print_warning("Could not clean build directory: " + std::string(e.what()));
        }
        
        print_success("Successfully installed " + pkg_name + "!");
        return true;
    }

public:
    Dreamland() {
        init_directories();
        curl_global_init(CURL_GLOBAL_DEFAULT);
        print_debug("Cache directory: " + cache_dir);
        print_debug("Data directory: " + fs::path(installed_db).parent_path().string());
    }

    ~Dreamland() {
        curl_global_cleanup();
    }
       // Load installed packages database
    void load_installed() {
        if (!fs::exists(installed_db)) {
            print_debug("No installed packages database: " + installed_db);
            return;
        }

        std::ifstream file(installed_db);
        if (!file.is_open()) {
            print_warning("Cannot read installed database: " + installed_db);
            return;
        }
        
        std::string line;
        int count = 0;
        
        while (std::getline(file, line)) {
            if (line.empty()) continue;
            
            size_t space_pos = line.find(' ');
            if (space_pos != std::string::npos) {
                std::string name = line.substr(0, space_pos);
                std::string version = line.substr(space_pos + 1);
                
                Package pkg;
                pkg.name = name;
                pkg.version = version;
                pkg.installed = true;
                installed[name] = pkg;
                count++;
            }
        }
        
        print_debug("Loaded " + std::to_string(count) + " installed packages");
    }
    // Make these public for main() to access
    bool remove_package(const std::string& pkg_name, bool auto_remove = false) {
        if (installed.find(pkg_name) == installed.end()) {
            print_warning(pkg_name + " is not installed");
            return false;
        }
        
        print_banner();
        std::cout << "Removing: " << PINK << pkg_name << RESET << "\n\n";
        
        // Find packages that depend on this one
        std::set<std::string> dependents = find_dependents(pkg_name);
        
        if (!dependents.empty() && !auto_remove) {
            print_error("Cannot remove " + pkg_name);
            std::cout << "\nThe following packages depend on it:\n";
            for (const auto& dep : dependents) {
                std::cout << "  • " << YELLOW << dep << RESET << "\n";
            }
            std::cout << "\nTo remove anyway (breaking these packages):\n";
            std::cout << "  dreamland remove --force " << pkg_name << "\n";
            std::cout << "\nTo remove with dependents:\n";
            std::cout << "  dreamland remove --cascade " << pkg_name << "\n";
            return false;
        }
        
        // Uninstall the package
        print_status("Uninstalling " + pkg_name + "...");
        
        // Try to find and run package-specific uninstall script
        bool uninstall_success = false;
        
        // Method 1: Check for uninstall manifest (if we tracked installed files)
        std::string manifest = fs::path(installed_db).parent_path().string() + 
                               "/manifests/" + pkg_name + ".files";
        
        if (fs::exists(manifest)) {
            print_status("Removing installed files...");
            std::ifstream mf(manifest);
            std::string file;
            int removed = 0;
            
            while (std::getline(mf, file)) {
                if (fs::exists(file)) {
                    try {
                        fs::remove(file);
                        removed++;
                    } catch (...) {
                        print_debug("Could not remove: " + file);
                    }
                }
            }
            print_success("Removed " + std::to_string(removed) + " files");
            uninstall_success = true;
        }
        
        // Method 2: Run package manager's uninstall (make uninstall, etc.)
        if (!uninstall_success) {
            print_warning("No uninstall manifest found");
            print_warning("Package files may remain in /usr");
            print_status("Attempting standard uninstall methods...");
            
            // Try common uninstall patterns
            std::vector<std::string> uninstall_commands = {
                "cd /tmp && make uninstall 2>/dev/null",
                "cd /tmp && ninja -C build uninstall 2>/dev/null",
                "cd /tmp && cmake --build build --target uninstall 2>/dev/null"
            };
            
            for (const auto& cmd : uninstall_commands) {
                if (execute_command(cmd) == 0) {
                    print_success("Uninstalled using package build system");
                    uninstall_success = true;
                    break;
                }
            }
            
            if (!uninstall_success) {
                print_warning("Could not automatically uninstall files");
                print_warning("You may need to manually remove files from /usr");
            }
        }
        
        // Remove from installed database
        installed.erase(pkg_name);
        save_installed();
        
        // Remove package cache
        std::string pkg_path = find_package_path(pkg_name);
        if (!pkg_path.empty()) {
            std::string local_pkg = cache_dir + "/" + pkg_path;
            if (fs::exists(local_pkg)) {
                fs::remove(local_pkg);
            }
        }
        
        print_success("Removed " + pkg_name + " from package database");
        
        // Check for orphaned dependencies (if auto-remove enabled)
        if (auto_remove) {
            print_status("Checking for orphaned dependencies...");
            
            // Load package info to get dependencies
            if (packages.count(pkg_name)) {
                const Package& pkg = packages[pkg_name];
                std::vector<std::string> orphans;
                
                for (const auto& dep : pkg.dependencies) {
                    // Check if any other installed package depends on this
                    std::set<std::string> dep_dependents = find_dependents(dep);
                    
                    // Remove the package we just uninstalled from the set
                    dep_dependents.erase(pkg_name);
                    
                    if (dep_dependents.empty() && installed.count(dep)) {
                        orphans.push_back(dep);
                    }
                }
                
                if (!orphans.empty()) {
                    std::cout << "\n";
                    print_status("Found " + std::to_string(orphans.size()) + " orphaned dependencies:");
                    for (const auto& orphan : orphans) {
                        std::cout << "  • " << YELLOW << orphan << RESET << "\n";
                    }
                    
                    std::cout << "\n";
                    std::string confirm;
                    std::cout << "Remove orphaned dependencies? (y/n) [y]: ";
                    std::getline(std::cin, confirm);
                    
                    if (confirm.empty() || confirm == "y" || confirm == "Y") {
                        for (const auto& orphan : orphans) {
                            std::cout << "\n";
                            remove_package(orphan, true);
                        }
                    }
                }
            }
        }
        
        std::cout << "\n";
        print_success("Successfully removed " + pkg_name + "!");
        return true;
    }

    void sync() {
        print_banner();
        print_status("Syncing with GitHub repository...");
        print_status("Repository: " GITHUB_REPO);
        std::cout << "Cache: " << cache_dir << "\n\n";
        
        if (!fetch_package_index()) {
            print_error("Failed to sync repository");
            print_warning("Make sure you have internet connection");
            print_warning("Check: " + std::string(GITHUB_RAW_URL) + "INDEX");
            return;
        }
        
        load_installed();
        print_success("Repository sync complete!");
    }

    void search(const std::string& query) {
        print_banner();
        load_package_index();
        load_installed();
        
        if (available_packages.empty()) {
            print_warning("Package index is empty. Run 'dreamland sync' first.");
            print_warning("Index location: " + pkg_index);
            return;
        }
        
        print_status("Searching for: " + query);
        print_debug("Searching through " + std::to_string(available_packages.size()) + " packages");
        std::cout << "\n";
        
        bool found = false;
        for (const auto& pkg_path : available_packages) {
            size_t last_slash = pkg_path.find_last_of('/');
            std::string filename = (last_slash != std::string::npos) 
                ? pkg_path.substr(last_slash + 1) 
                : pkg_path;
            
            size_t ext_pos = filename.find_last_of('.');
            std::string name = (ext_pos != std::string::npos) 
                ? filename.substr(0, ext_pos) 
                : filename;
            
            if (name.find(query) != std::string::npos || 
                pkg_path.find(query) != std::string::npos) {
                
                bool is_installed = installed.find(name) != installed.end();
                std::string status = is_installed ? GREEN " [installed]" RESET : "";
                
                std::string category = (last_slash != std::string::npos) 
                    ? pkg_path.substr(0, last_slash) 
                    : "unknown";
                
                std::cout << PINK << name << RESET << status << " (" << category << ")\n";
                found = true;
            }
        }
        
        if (!found) {
            print_warning("No packages found matching: " + query);
            std::cout << "\nTry:\n";
            std::cout << "  dreamland sync         # Update package index\n";
            std::cout << "  dreamland search vim   # Different search term\n";
        }
    }

    bool install_package(const std::string& pkg_name) {
        load_package_index();
        load_installed();
        
        if (available_packages.empty()) {
            print_warning("Package index is empty. Run 'dreamland sync' first.");
            return false;
        }
        
        // Check if already installed
        if (installed.find(pkg_name) != installed.end()) {
            print_warning(pkg_name + " is already installed");
            return true;
        }
        
        // Resolve full dependency tree
        print_status("Resolving dependencies for " + pkg_name + "...");
        std::vector<std::string> install_order = resolve_dependencies(pkg_name);
        
        if (install_order.empty()) {
            print_error("Failed to resolve dependencies");
            return false;
        }
        
        // Show installation plan
        std::cout << "\n";
        print_status("Installation plan:");
        int to_install = 0;
        for (const auto& name : install_order) {
            if (!installed.count(name)) {
                std::cout << "  " << (++to_install) << ". " << PINK << name << RESET << "\n";
            }
        }
        
        if (to_install == 0) {
            print_success("All dependencies already satisfied!");
            return true;
        }
        
        std::cout << "\n";
        std::cout << "Total packages to install: " << to_install << "\n";
        std::cout << "Estimated time: " << (to_install * 5) << "-" << (to_install * 15) << " minutes\n\n";
        
        std::string confirm;
        std::cout << "Continue? (y/n) [y]: ";
        std::getline(std::cin, confirm);
        
        if (!confirm.empty() && confirm != "y" && confirm != "Y") {
            print_warning("Installation cancelled");
            return false;
        }
        
        // Install packages in order
        int current = 0;
        for (const auto& name : install_order) {
            if (installed.count(name)) {
                continue;
            }
            
            current++;
            std::cout << "\n";
            std::cout << BLUE << "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" << RESET << "\n";
            
            if (!install_package_internal(name)) {
                print_error("Failed to install " + name);
                print_error("Stopping installation");
                return false;
            }
        }
        
        std::cout << "\n";
        std::cout << GREEN << "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" << RESET << "\n";
        std::cout << GREEN << "Installation Complete!" << RESET << "\n";
        std::cout << GREEN << "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" << RESET << "\n\n";
        
        print_success("Successfully installed " + pkg_name + " and all dependencies!");
        
        return true;
    }

    void list_installed() {
        print_banner();
        load_installed();
        
        if (installed.empty()) {
            print_warning("No packages installed");
            std::cout << "\nTry:\n";
            std::cout << "  dreamland sync           # Update package list\n";
            std::cout << "  dreamland search editor  # Find packages\n";
            std::cout << "  dreamland install vim    # Install a package\n";
            return;
        }
        
        std::cout << "Installed packages (" << installed.size() << "):\n\n";
        for (const auto& [name, pkg] : installed) {
            std::cout << PINK << name << RESET << " " << pkg.version << "\n";
        }
        
        std::cout << "\nDatabase: " << installed_db << "\n";
    }

    void clean() {
        print_banner();
        print_status("Cleaning build directories and cache...");
        
        size_t build_size = 0;
        size_t cache_size = 0;
        
        if (fs::exists(build_dir)) {
            try {
                for (const auto& entry : fs::recursive_directory_iterator(build_dir)) {
                    if (fs::is_regular_file(entry)) {
                        build_size += fs::file_size(entry);
                    }
                }
            } catch (const fs::filesystem_error& e) {
                print_warning("Error calculating build size: " + std::string(e.what()));
            }
        }
        
        if (fs::exists(cache_dir)) {
            try {
                for (const auto& entry : fs::recursive_directory_iterator(cache_dir)) {
                    if (fs::is_regular_file(entry)) {
                        cache_size += fs::file_size(entry);
                    }
                }
            } catch (const fs::filesystem_error& e) {
                print_warning("Error calculating cache size: " + std::string(e.what()));
            }
        }
        
        std::cout << "Build directory: " << (build_size / 1024.0 / 1024.0) << " MB\n";
        std::cout << "Cache directory: " << (cache_size / 1024.0 / 1024.0) << " MB\n";
        std::cout << "Total: " << ((build_size + cache_size) / 1024.0 / 1024.0) << " MB\n\n";
        
        std::cout << "This will remove:\n";
        std::cout << "  • All build directories\n";
        std::cout << "  • Downloaded package definitions\n";
        std::cout << "  • Source archives\n";
        std::cout << "  • Keep: installed packages database\n\n";
        
        std::string confirm;
        std::cout << "Continue? (y/n): ";
        std::getline(std::cin, confirm);
        
        if (confirm != "y" && confirm != "Y") {
            print_warning("Clean cancelled");
            return;
        }
        
        if (fs::exists(build_dir)) {
            try {
                fs::remove_all(build_dir);
                fs::create_directories(build_dir);
                print_success("Cleaned build directory");
            } catch (const fs::filesystem_error& e) {
                print_error("Error cleaning build directory: " + std::string(e.what()));
            }
        }
        
        if (fs::exists(cache_dir)) {
            try {
                for (const auto& entry : fs::directory_iterator(cache_dir)) {
                    if (entry.path().filename() != "package_index.txt") {
                        fs::remove_all(entry);
                    }
                }
                print_success("Cleaned cache directory");
            } catch (const fs::filesystem_error& e) {
                print_error("Error cleaning cache: " + std::string(e.what()));
            }
        }
        
        execute_command("rm -f /tmp/*.tar.* /tmp/*.tgz /tmp/*.zip 2>/dev/null");
        
        double freed_mb = (build_size + cache_size) / 1024.0 / 1024.0;
        print_success("Clean complete! Freed " + std::to_string(freed_mb) + " MB");
    }

    // Find what packages depend on a given package
    std::set<std::string> find_dependents(const std::string& pkg_name) {
        std::set<std::string> dependents;
        
        // Check all installed packages
        for (const auto& [name, pkg] : installed) {
            // Load package definition if not in cache
            if (packages.find(name) == packages.end()) {
                std::string pkg_path = find_package_path(name);
                if (!pkg_path.empty()) {
                    download_package_definition(pkg_path);
                    std::string local_pkg = cache_dir + "/" + pkg_path;
                    Package loaded_pkg;
                    if (parse_package(local_pkg, loaded_pkg)) {
                        packages[name] = loaded_pkg;
                    }
                }
            }
            
            // Check if this package depends on pkg_name
            if (packages.count(name)) {
                const Package& p = packages[name];
                for (const auto& dep : p.dependencies) {
                    if (dep == pkg_name) {
                        dependents.insert(name);
                        break;
                    }
                }
            }
        }
        
        return dependents;
    }
    
    // Remove a package and optionally its dependencies
      void show_usage(const std::string& prog) {
        print_banner();
        std::cout << "Usage: " << prog << " <command> [options]\n\n";
        std::cout << "Commands:\n";
        std::cout << "  sync                Sync package index from GitHub\n";
        std::cout << "  install <package>   Install a package from source (with dependencies)\n";
        std::cout << "  remove <package>    Remove an installed package\n";
        std::cout << "  search <query>      Search for packages\n";
        std::cout << "  list                List installed packages\n";
        std::cout << "  clean               Clean build cache and temporary files\n";
        std::cout << "  info <package>      Show package information\n";
        std::cout << "\nRemoval Options:\n";
        std::cout << "  remove <package>           Remove package (fails if depended upon)\n";
        std::cout << "  remove --cascade <package> Remove package and dependents\n";
        std::cout << "  remove --force <package>   Force remove (may break dependencies)\n";
        std::cout << "  autoremove                 Remove orphaned dependencies\n";
        std::cout << "\nExamples:\n";
        std::cout << "  " << prog << " sync\n";
        std::cout << "  " << prog << " search editor\n";
        std::cout << "  " << prog << " install neovim     # Installs neovim + all dependencies\n";
        std::cout << "  " << prog << " install wlroots    # Installs wlroots + 20+ dependencies\n";
        std::cout << "  " << prog << " remove neovim      # Removes neovim, keeps dependencies\n";
        std::cout << "  " << prog << " autoremove         # Removes unused dependencies\n";
        std::cout << "  dl install nginx               (short command)\n";
        std::cout << "  dl clean                       (free up disk space)\n";
        std::cout << "\nFeatures:\n";
        std::cout << "  • Automatic dependency resolution\n";
        std::cout << "  • Topological sort for correct install order\n";
        std::cout << "  • Circular dependency detection\n";
        std::cout << "  • Shows installation plan before building\n";
        std::cout << "  • Dependency-aware uninstall\n";
        std::cout << "  • Orphaned package detection\n";
        std::cout << "\nConfiguration:\n";
        std::cout << "  Cache:  " << cache_dir << "\n";
        std::cout << "  Data:   " << fs::path(installed_db).parent_path().string() << "\n";
        std::cout << "\nRepository: " GITHUB_REPO "\n";
    }
    
    // Auto-remove orphaned packages
    void autoremove() {
        print_banner();
        load_installed();
        
        if (installed.empty()) {
            print_warning("No packages installed");
            return;
        }
        
        print_status("Finding orphaned packages...");
        
        std::set<std::string> orphans;
        
        // For each installed package, check if anything depends on it
        for (const auto& [name, pkg] : installed) {
            std::set<std::string> dependents = find_dependents(name);
            
            if (dependents.empty()) {
                // Check if this package was manually installed
                // For now, consider packages with no dependents as potential orphans
                // We'd need to track "manually installed" vs "auto installed as dependency"
                // For simplicity, just show packages nothing depends on
                orphans.insert(name);
            }
        }
        
        if (orphans.empty()) {
            print_success("No orphaned packages found");
            return;
        }
        
        std::cout << "\n";
        print_status("Found " + std::to_string(orphans.size()) + " packages with no dependents:");
        std::cout << "\n";
        
        for (const auto& orphan : orphans) {
            std::cout << "  • " << YELLOW << orphan << RESET;
            if (installed.count(orphan)) {
                std::cout << " " << installed[orphan].version;
            }
            std::cout << "\n";
        }
        
        std::cout << "\n";
        print_warning("Note: This shows ALL packages nothing depends on");
        print_warning("Some may have been manually installed");
        std::cout << "\n";
        
        std::string confirm;
        std::cout << "Remove these packages? (y/n) [n]: ";
        std::getline(std::cin, confirm);
        
        if (confirm == "y" || confirm == "Y") {
            for (const auto& orphan : orphans) {
                std::cout << "\n";
                remove_package(orphan, false);
            }
        } else {
            print_warning("Cancelled");
        }
    }
};

int main(int argc, char* argv[]) {
    try {
        Dreamland dl;
        
        if (argc < 2) {
            dl.show_usage(argv[0]);
            return 1;
        }
        
        std::string command = argv[1];
        
        if (command == "sync") {
            dl.sync();
        }
        else if (command == "search" && argc >= 3) {
            dl.search(argv[2]);
        }
        else if (command == "install" && argc >= 3) {
            return dl.install_package(argv[2]) ? 0 : 1;
        }
        else if (command == "remove" && argc >= 3) {
            std::string pkg_name = argv[2];
            bool cascade = false;
            bool force = false;
            
            // Check for flags
            if (argc >= 4) {
                pkg_name = argv[3];
                std::string flag = argv[2];
                if (flag == "--cascade") {
                    cascade = true;
                } else if (flag == "--force") {
                    force = true;
                }
            }
            
            if (cascade) {
                // Remove package and all dependents
                dl.load_installed();
                std::set<std::string> to_remove;
                to_remove.insert(pkg_name);
                
                // Find all dependents recursively
                std::queue<std::string> queue;
                queue.push(pkg_name);
                
                while (!queue.empty()) {
                    std::string current = queue.front();
                    queue.pop();
                    
                    auto dependents = dl.find_dependents(current);
                    for (const auto& dep : dependents) {
                        if (!to_remove.count(dep)) {
                            to_remove.insert(dep);
                            queue.push(dep);
                        }
                    }
                }
                
                std::cout << "\n";
                std::cout << "The following packages will be removed:\n";
                for (const auto& pkg : to_remove) {
                    std::cout << "  • " << pkg << "\n";
                }
                std::cout << "\nTotal: " << to_remove.size() << " packages\n\n";
                
                std::string confirm;
                std::cout << "Continue? (y/n) [n]: ";
                std::getline(std::cin, confirm);
                
                if (confirm == "y" || confirm == "Y") {
                    for (const auto& pkg : to_remove) {
                        dl.remove_package(pkg, false);
                    }
                }
            } else if (force) {
                // Force remove without checking dependents
                dl.remove_package(pkg_name, true);
            } else {
                // Normal remove (checks for dependents)
                return dl.remove_package(pkg_name, true) ? 0 : 1;
            }
        }
        else if (command == "autoremove") {
            dl.autoremove();
        }
        else if (command == "list") {
            dl.list_installed();
        }
        else if (command == "clean") {
            dl.clean();
        }
        else {
            dl.show_usage(argv[0]);
            return 1;
        }
        
        return 0;
        
    } catch (const std::exception& e) {
        std::cerr << RED << "[✗] Fatal error: " << e.what() << RESET << std::endl;
        return 1;
    }

}
