#include <archive.h>
#include <archive_entry.h>
#include <curl/curl.h>
#include "dreamland.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <iostream>
#include <sstream>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
const std::vector<std::string> ARCH_MIRRORS = {
    "https://mirror.rackspace.com/archlinux",
    "https://mirrors.kernel.org/archlinux",
    "https://geo.mirror.pkgbuild.com",
};
const std::vector<std::string> ARCH_REPOS = {"core", "extra"};

// ── curl callbacks ────────────────────────────────────────────────────────────

size_t write_cb(void* c, size_t s, size_t n, std::string* o) {
    o->append((char*)c, s * n);
    return s * n;
}
size_t write_file_cb(void* c, size_t s, size_t n, FILE* f) {
    return fwrite(c, s, n, f);
}

int progress_cb(void* p, curl_off_t dltotal, curl_off_t dlnow, curl_off_t, curl_off_t) {
    if (dltotal <= 0) return 0;
    auto* pd = static_cast<ProgressData*>(p);
    int pct  = (int)(dlnow * 100 / dltotal);
    int fill = pct / 2;
    std::string bar(fill, '=');
    bar += std::string(50 - fill, '-');
    fprintf(stderr, "\r  %s [%s] %d%%  ", pd->label.c_str(), bar.c_str(), pct);
    if (dlnow >= dltotal) fprintf(stderr, "\n");
    return 0;
}

// ── Dreamland ctor/dtor ───────────────────────────────────────────────────────

Dreamland::Dreamland() {
    init();
    curl_global_init(CURL_GLOBAL_DEFAULT);
    load_all_mods();
}
Dreamland::~Dreamland() {
    unload_mods();
    curl_global_cleanup();
}

// ── Init ──────────────────────────────────────────────────────────────────────

std::string Dreamland::home() {
    const char* h = getenv("HOME");
    return h ? h : "/tmp";
}

void Dreamland::init() {
    std::string h  = home();
    const char* xc = getenv("XDG_CACHE_HOME");
    const char* xd = getenv("XDG_DATA_HOME");
    std::string bc = xc ? xc : h + "/.cache";
    std::string bd = xd ? xd : h + "/.local/share";

    cache_dir    = bc + "/dreamland";
    build_dir    = cache_dir + "/build";
    pkg_index    = cache_dir + "/package_index.txt";
    pkg_cache_dir = cache_dir + "/packages";
    db_cache_dir  = cache_dir + "/db";

    installed_db = bd + "/dreamland/installed.db";
    pkg_db       = bd + "/dreamland/packages.db";
    manifest_dir = bd + "/dreamland/manifests";

    module_search_paths = {"/usr/local/share/dreamland/modules",
                           bd + "/dreamland/modules"};
    for (auto& path : module_search_paths) {
        if (fs::exists(path) && access(path.c_str(), W_OK) == 0) {
            modules_dir = path;
            break;
        }
    }
    if (modules_dir.empty()) modules_dir = module_search_paths.back();

    debug = getenv("DREAMLAND_DEBUG") &&
            std::string(getenv("DREAMLAND_DEBUG")) == "1";

    fs::create_directories(cache_dir);
    fs::create_directories(build_dir);
    fs::create_directories(pkg_cache_dir);
    fs::create_directories(db_cache_dir);
    fs::create_directories(fs::path(installed_db).parent_path());
    fs::create_directories(manifest_dir);
    try { fs::create_directories(modules_dir); } catch (...) {}
}

// ── Lazy loaders ──────────────────────────────────────────────────────────────

void Dreamland::ensure_db() {
    if (!db_loaded) { load_pkg_db(); db_loaded = true; }
}
void Dreamland::ensure_installed() {
    if (!inst_loaded) { load_installed(); inst_loaded = true; }
}

// ── Logging ───────────────────────────────────────────────────────────────────

void Dreamland::banner() {
    std::cout << PINK << "    ★ DREAMLAND ★\n    User's Choice\n" << RESET << "\n";
}
void Dreamland::status(const std::string& m) { std::cout << BLUE  << "[★] " << RESET << m << "\n"; }
void Dreamland::ok(const std::string& m)     { std::cout << GREEN << "[✓] " << RESET << m << "\n"; }
void Dreamland::err(const std::string& m)    { std::cerr << RED   << "[✗] " << RESET << m << "\n"; }
void Dreamland::warn(const std::string& m)   { std::cout << YELLOW<< "[!] " << RESET << m << "\n"; }
void Dreamland::dbg(const std::string& m)    { if (debug) std::cout << "[D] " << m << "\n"; }

// ── Shell exec ────────────────────────────────────────────────────────────────

int Dreamland::exec(const std::string& cmd) {
    return WEXITSTATUS(system(cmd.c_str()));
}

// ── Network ───────────────────────────────────────────────────────────────────

bool Dreamland::dl_str(const std::string& url, std::string& out) {
    CURL* c = curl_easy_init();
    if (!c) return false;
    curl_easy_setopt(c, CURLOPT_URL,           url.c_str());
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(c, CURLOPT_WRITEDATA,     &out);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION,1L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER,0L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT,       30L);
    CURLcode r = curl_easy_perform(c);
    long rc; curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &rc);
    curl_easy_cleanup(c);
    return r == CURLE_OK && rc == 200;
}

bool Dreamland::dl_file(const std::string& url, const std::string& path,
                        const std::string& label) {
    if (fs::exists(path) && fs::file_size(path) > 0) {
        dbg("Using cached: " + path);
        return true;
    }
    CURL* c = curl_easy_init();
    if (!c) { err("Failed to init CURL"); return false; }

    try { fs::create_directories(fs::path(path).parent_path()); }
    catch (const std::exception& e) { err("mkdir failed: " + std::string(e.what())); curl_easy_cleanup(c); return false; }

    FILE* f = fopen(path.c_str(), "wb");
    if (!f) { err("Cannot open for write: " + path); curl_easy_cleanup(c); return false; }

    ProgressData pd{ label.empty() ? fs::path(path).filename().string() : label };

    curl_easy_setopt(c, CURLOPT_URL,              url.c_str());
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION,    write_file_cb);
    curl_easy_setopt(c, CURLOPT_WRITEDATA,        f);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION,   1L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER,   0L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT,          300L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT,   30L);
    curl_easy_setopt(c, CURLOPT_FAILONERROR,      1L);
    curl_easy_setopt(c, CURLOPT_XFERINFOFUNCTION, progress_cb);
    curl_easy_setopt(c, CURLOPT_XFERINFODATA,     &pd);
    curl_easy_setopt(c, CURLOPT_NOPROGRESS,       0L);

    CURLcode r = curl_easy_perform(c);
    long rc; curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &rc);
    fclose(f);
    curl_easy_cleanup(c);

    if (r != CURLE_OK || rc != 200) {
        dbg("Download failed: " + std::string(curl_easy_strerror(r)) +
            " HTTP " + std::to_string(rc) + " url=" + url);
        fs::remove(path);
        return false;
    }
    if (!fs::exists(path) || fs::file_size(path) == 0) {
        fs::remove(path);
        return false;
    }
    return true;
}

// ── Archive extraction ────────────────────────────────────────────────────────

bool Dreamland::extract_pkg(const std::string& pkg, const std::string& dest,
                             std::vector<std::string>* files) {
    struct archive* a   = archive_read_new();
    struct archive* ext = archive_write_disk_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    archive_write_disk_set_options(ext, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM);

    if (archive_read_open_filename(a, pkg.c_str(), 10240) != ARCHIVE_OK) {
        archive_read_free(a); archive_write_free(ext);
        return false;
    }

    struct archive_entry* entry;
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        std::string pn = archive_entry_pathname(entry);
        if (pn[0] == '.' && (pn.find(".PKGINFO") != std::string::npos ||
                              pn.find(".MTREE")   != std::string::npos))
            continue;
        std::string fp = dest.empty() ? pn : dest + "/" + pn;
        archive_entry_set_pathname(entry, fp.c_str());
        if (archive_write_header(ext, entry) == ARCHIVE_OK) {
            if (files && archive_entry_filetype(entry) == AE_IFREG)
                files->push_back("/" + pn);
            const void* buf; size_t sz; int64_t off;
            while (archive_read_data_block(a, &buf, &sz, &off) == ARCHIVE_OK)
                archive_write_data_block(ext, buf, sz, off);
        }
    }
    archive_read_close(a);  archive_read_free(a);
    archive_write_close(ext); archive_write_free(ext);
    return true;
}
