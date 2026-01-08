#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <filesystem>
#include <cstdlib>
#include <unistd.h>
#include <sys/wait.h>
#include <curl/curl.h>

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

    // Get user's home directory
    std::string get_home_dir() {
        const char* home = getenv("HOME");
        if (home) {
            return std::string(home);
        }
        
        // Fallback to /tmp if HOME not set
        return "/tmp";
    }

    // Initialize directory paths based on XDG standards
    void init_directories() {
        std::string home = get_home_dir();
        
        // Check for XDG_CACHE_HOME
        const char* xdg_cache = getenv("XDG_CACHE_HOME");
        std::string base_cache = xdg_cache ? std::string(xdg_cache) : home + "/.cache";
        
        // Check for XDG_DATA_HOME
        const char* xdg_data = getenv("XDG_DATA_HOME");
        std::string base_data = xdg_data ? std::string(xdg_data) : home + "/.local/share";
        
        // Set up Dreamland directories
        cache_dir = base_cache + "/dreamland";
        build_dir = cache_dir + "/build";
        pkg_index = cache_dir + "/package_index.txt";
        
        installed_db = base_data + "/dreamland/installed.db";
        pkg_db = base_data + "/dreamland/packages.db";
        
        // Create all necessary directories
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
            return false;
        }

        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &output);
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "Dreamland/1.0");
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
        
        CURLcode res = curl_easy_perform(curl);
        long response_code;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
        curl_easy_cleanup(curl);

        if (res != CURLE_OK) {
            print_debug("CURL error: " + std::string(curl_easy_strerror(res)));
        }

        return (res == CURLE_OK && response_code == 200);
    }

    // Download file from URL to file
    bool download_file(const std::string& url, const std::string& filepath) {
        std::string content;
        if (!download_url(url, content)) {
            return false;
        }

        // Ensure parent directory exists
        fs::create_directories(fs::path(filepath).parent_path());

        std::ofstream file(filepath);
        if (!file.is_open()) {
            print_error("Cannot open file for writing: " + filepath);
            return false;
        }

        file << content;
        file.close();
        
        // Verify file was written
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

        // Save to local file
        std::ofstream index_file(pkg_index);
        if (!index_file.is_open()) {
            print_error("Cannot write to: " + pkg_index);
            print_warning("Check permissions for: " + cache_dir);
            return false;
        }
        
        index_file << index_content;
        index_file.close();
        
        // Verify it was written
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
            // Trim whitespace
            line.erase(0, line.find_first_not_of(" \t\r\n"));
            line.erase(line.find_last_not_of(" \t\r\n") + 1);
            
            // Format: category/package_name.pkg
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
            // Trim whitespace
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
        
        // Create directory structure
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
            
            // Trim whitespace
            line.erase(0, line.find_first_not_of(" \t\r\n"));
            line.erase(line.find_last_not_of(" \t\r\n") + 1);
            
            // Skip empty lines and comments
            if (line.empty() || line[0] == '#') continue;
            
            // Section headers
            if (line[0] == '[' && line[line.length()-1] == ']') {
                current_section = line.substr(1, line.length()-2);
                print_debug("Parsing section: " + current_section);
                continue;
            }
            
            // Parse key=value pairs
            size_t eq_pos = line.find('=');
            if (eq_pos == std::string::npos) {
                // If in Script section and no =, it's part of the script
                if (current_section == "Script") {
                    pkg.build_script += line + "\n";
                }
                continue;
            }
            
            std::string key = line.substr(0, eq_pos);
            std::string value = line.substr(eq_pos + 1);
            
            // Trim
            key.erase(0, key.find_first_not_of(" \t"));
            key.erase(key.find_last_not_of(" \t") + 1);
            value.erase(0, value.find_first_not_of(" \t"));
            value.erase(value.find_last_not_of(" \t") + 1);
            
            // Remove quotes
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
            // Extract filename without extension
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

    // Save installed packages database
    void save_installed() {
        // Ensure directory exists
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

    // Download source code
    bool download_source(const Package& pkg, const std::string& dest) {
        print_status("Downloading " + pkg.name + " source...");
        
        std::string cmd;
        if (pkg.url.find(".git") != std::string::npos) {
            cmd = "git clone " + pkg.url + " " + dest;
        } else {
            std::string ext = pkg.url.substr(pkg.url.find_last_of('.'));
            std::string archive = "/tmp/" + pkg.name + ext;
            
            cmd = "wget -q -O " + archive + " " + pkg.url;
            if (execute_command(cmd) != 0) {
                cmd = "curl -s -L -o " + archive + " " + pkg.url;
                if (execute_command(cmd) != 0) {
                    print_error("Failed to download source (tried wget and curl)");
                    return false;
                }
            }
            
            // Extract based on extension
            if (ext == ".gz" || ext == ".tgz") {
                cmd = "tar -xzf " + archive + " -C " + dest + " --strip-components=1 2>/dev/null";
            } else if (ext == ".bz2") {
                cmd = "tar -xjf " + archive + " -C " + dest + " --strip-components=1 2>/dev/null";
            } else if (ext == ".xz") {
                cmd = "tar -xJf " + archive + " -C " + dest + " --strip-components=1 2>/dev/null";
            } else if (ext == ".zip") {
                cmd = "unzip -q " + archive + " -d " + dest + " 2>/dev/null";
            } else {
                print_error("Unknown archive format: " + ext);
                return false;
            }
        }
        
        return execute_command(cmd) == 0;
    }

    // Build package from source
    bool build_package(const Package& pkg, const std::string& build_path) {
        print_status("Building " + pkg.name + "...");
        
        // Create build script
        std::string script_path = build_path + "/dreamland_build.sh";
        std::ofstream script(script_path);
        
        if (!script.is_open()) {
            print_error("Cannot create build script: " + script_path);
            return false;
        }
        
        script << "#!/bin/bash\n";
        script << "set -e\n\n";
        script << "cd " << build_path << "\n\n";
        
        // Set build flags
        for (const auto& [key, value] : pkg.build_flags) {
            script << "export " << key << "=\"" << value << "\"\n";
        }
        script << "\n";
        
        // Default build process if no custom script
        if (pkg.build_script.empty()) {
            script << "# Default build process\n";
            script << "if [ -f configure ]; then\n";
            script << "    ./configure --prefix=/usr\n";
            script << "    make -j$(nproc)\n";
            script << "    make install\n";
            script << "elif [ -f CMakeLists.txt ]; then\n";
            script << "    cmake -B build -DCMAKE_INSTALL_PREFIX=/usr\n";
            script << "    cmake --build build -j$(nproc)\n";
            script << "    cmake --install build\n";
            script << "elif [ -f Makefile ]; then\n";
            script << "    make -j$(nproc)\n";
            script << "    make install\n";
            script << "else\n";
            script << "    echo 'No build system detected'\n";
            script << "    exit 1\n";
            script << "fi\n";
        } else {
            script << pkg.build_script;
        }
        
        script.close();
        
        // Make executable
        try {
            fs::permissions(script_path, 
                fs::perms::owner_exec | fs::perms::owner_read | fs::perms::owner_write,
                fs::perm_options::add);
        } catch (const fs::filesystem_error& e) {
            print_error("Cannot set permissions: " + std::string(e.what()));
            return false;
        }
        
        // Execute build script
        int result = execute_command("bash " + script_path + " 2>&1 | tee " + build_path + "/build.log");
        
        if (result == 0) {
            print_success("Built " + pkg.name + " successfully");
            return true;
        } else {
            print_error("Failed to build " + pkg.name);
            print_warning("Check build log: " + build_path + "/build.log");
            return false;
        }
    }

    // Check and install dependencies
    bool install_dependencies(const Package& pkg) {
        if (pkg.dependencies.empty()) {
            return true;
        }

        print_status("Checking dependencies for " + pkg.name + "...");
        
        for (const auto& dep : pkg.dependencies) {
            if (installed.find(dep) != installed.end()) {
                print_success(dep + " already installed");
                continue;
            }
            
            print_status("Installing dependency: " + dep);
            if (!install_package(dep)) {
                print_error("Failed to install dependency: " + dep);
                return false;
            }
        }
        
        return true;
    }

public:
    Dreamland() {
        // Initialize directory paths
        init_directories();
        
        // Initialize curl
        curl_global_init(CURL_GLOBAL_DEFAULT);
        
        print_debug("Cache directory: " + cache_dir);
        print_debug("Data directory: " + fs::path(installed_db).parent_path().string());
    }

    ~Dreamland() {
        curl_global_cleanup();
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
            // Extract package name from path
            size_t last_slash = pkg_path.find_last_of('/');
            std::string filename = (last_slash != std::string::npos) 
                ? pkg_path.substr(last_slash + 1) 
                : pkg_path;
            
            size_t ext_pos = filename.find_last_of('.');
            std::string name = (ext_pos != std::string::npos) 
                ? filename.substr(0, ext_pos) 
                : filename;
            
            // Simple search - check if query is in name or path
            if (name.find(query) != std::string::npos || 
                pkg_path.find(query) != std::string::npos) {
                
                bool is_installed = installed.find(name) != installed.end();
                std::string status = is_installed ? GREEN " [installed]" RESET : "";
                
                // Extract category
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
        
        // Find package in index
        std::string pkg_path = find_package_path(pkg_name);
        if (pkg_path.empty()) {
            print_error("Package not found: " + pkg_name);
            print_warning("Try: dreamland search " + pkg_name);
            return false;
        }
        
        // Download package definition
        if (!download_package_definition(pkg_path)) {
            return false;
        }
        
        // Parse package
        std::string local_pkg = cache_dir + "/" + pkg_path;
        Package pkg;
        if (!parse_package(local_pkg, pkg)) {
            print_error("Failed to parse package definition");
            return false;
        }
        
        print_banner();
        std::cout << "Installing: " << PINK << pkg.name << RESET << " " << pkg.version << "\n";
        std::cout << pkg.description << "\n\n";
        
        // Install dependencies
        if (!install_dependencies(pkg)) {
            return false;
        }
        
        // Create build directory
        std::string build_path = build_dir + "/" + pkg_name;
        try {
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
        pkg.installed = true;
        installed[pkg_name] = pkg;
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
        
        // Calculate sizes
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
        
        // Clean build directory
        if (fs::exists(build_dir)) {
            try {
                fs::remove_all(build_dir);
                fs::create_directories(build_dir);
                print_success("Cleaned build directory");
            } catch (const fs::filesystem_error& e) {
                print_error("Error cleaning build directory: " + std::string(e.what()));
            }
        }
        
        // Clean cache (but keep package index)
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
        
        // Clean /tmp archives
        execute_command("rm -f /tmp/*.tar.* /tmp/*.tgz /tmp/*.zip 2>/dev/null");
        
        double freed_mb = (build_size + cache_size) / 1024.0 / 1024.0;
        print_success("Clean complete! Freed " + std::to_string(freed_mb) + " MB");
    }

    void show_usage(const std::string& prog) {
        print_banner();
        std::cout << "Usage: " << prog << " <command> [options]\n\n";
        std::cout << "Commands:\n";
        std::cout << "  sync                Sync package index from GitHub\n";
        std::cout << "  install <package>   Install a package from source\n";
        std::cout << "  remove <package>    Remove an installed package\n";
        std::cout << "  search <query>      Search for packages\n";
        std::cout << "  list                List installed packages\n";
        std::cout << "  clean               Clean build cache and temporary files\n";
        std::cout << "  info <package>      Show package information\n";
        std::cout << "\nExamples:\n";
        std::cout << "  " << prog << " sync\n";
        std::cout << "  " << prog << " search editor\n";
        std::cout << "  " << prog << " install vim\n";
        std::cout << "  dl install nginx    (short command)\n";
        std::cout << "  dl clean            (free up disk space)\n";
        std::cout << "\nConfiguration:\n";
        std::cout << "  Cache:  " << cache_dir << "\n";
        std::cout << "  Data:   " << fs::path(installed_db).parent_path().string() << "\n";
        std::cout << "\nRepository: " GITHUB_REPO "\n";
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
