#pragma once
#include "dreamland_module.h"
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace fs = std::filesystem;

#define PINK   "\033[38;5;213m"
#define BLUE   "\033[38;5;117m"
#define GREEN  "\033[0;32m"
#define YELLOW "\033[1;33m"
#define RED    "\033[0;31m"
#define CYAN   "\033[0;36m"
#define RESET  "\033[0m"

#define GALACTICA_REPO    "LinkNavi/GalacticaRepository"
#define GALACTICA_RAW_URL "https://raw.githubusercontent.com/" GALACTICA_REPO "/main/"

extern const std::vector<std::string> ARCH_MIRRORS;
extern const std::vector<std::string> ARCH_REPOS;

enum class PackageSource { GALACTICA, ARCH_BINARY, MODULE, UNKNOWN };

struct Package {
    std::string name, version, description, url, category, repo, filename,
                build_script, type;
    std::vector<std::string>           dependencies;
    std::map<std::string, std::string> build_flags;
    bool          installed     = false;
    bool          deps_resolved = false;
    PackageSource source        = PackageSource::UNKNOWN;
    size_t        size          = 0;
};

struct LoadedModule {
    void*                         handle;
    DreamlandModuleInfo*          info;
    std::vector<DreamlandCommand> commands;
    dreamland_module_cleanup_fn   cleanup;
};

struct ProgressData { std::string label; };

class Dreamland {
public:
    Dreamland();
    ~Dreamland();

    void sync();
    bool install(const std::string& name, bool reinstall = false);
    bool install_multi(const std::vector<std::string>& names,
                       bool reinstall = false, bool yes = false);
    bool uninstall(const std::string& name);
    void upgrade();
    void search(const std::string& q);
    void list();
    void info(const std::string& name);
    void files(const std::string& name);
    void clean();
    void list_mods();
    void usage(const std::string& prog);
    bool has_cmd(const std::string& cmd);
    bool run_cmd(int argc, char** argv);

private:
    std::string cache_dir, pkg_db, build_dir, installed_db,
                pkg_index, pkg_cache_dir, db_cache_dir,
                manifest_dir, modules_dir;

    bool debug       = false;
    bool db_loaded   = false;
    bool inst_loaded = false;

    std::map<std::string, Package>      packages;
    std::map<std::string, Package>      installed;
    std::set<std::string>               galactica_pkgs;
    std::map<std::string, LoadedModule> modules;
    std::vector<std::string>            module_search_paths;

    void        init();
    std::string home();
    void        ensure_db();
    void        ensure_installed();

    void banner();
    void status(const std::string& m);
    void ok(const std::string& m);
    void err(const std::string& m);
    void warn(const std::string& m);
    void dbg(const std::string& m);

    bool dl_str(const std::string& url, std::string& out);
    bool dl_file(const std::string& url, const std::string& path,
                 const std::string& label = "");

    void save_pkg_db();
    void load_pkg_db();
    void save_installed();
    void load_installed();
    static std::string base64_encode(const std::string& in);
    static std::string base64_decode(const std::string& in);

    bool fetch_galactica();
    bool parse_galactica_pkg(const std::string& pkg_path);
    bool load_galactica_packages();

    bool sync_arch();
    bool parse_arch_db_with_deps(const std::string& db, const std::string& repo);

    std::string              resolve_lib_to_pkg(const std::string& dep);
    std::vector<std::string> resolve_dependencies(const std::string& pkg_name,
                                                   std::set<std::string>& resolved,
                                                   std::set<std::string>& visited);

    bool install_arch(const Package& p);
    bool install_galactica(const Package& p_in);
    bool install_kernel(const Package& p);
    bool uninstall_pkg(const std::string& name);

    bool extract_pkg(const std::string& pkg, const std::string& dest,
                     std::vector<std::string>* files = nullptr);

    void load_all_mods();
    bool load_mod(const std::string& path);
    void unload_mods();

    int exec(const std::string& cmd);
};
