#include "ebuild.h"
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <filesystem>
#include <sstream>

namespace fs = std::filesystem;

// Gentoo portage tree on GitHub
static const char *GENTOO_GITHUB = "https://raw.githubusercontent.com/gentoo/gentoo/master";

// Fetch a URL to a local file using curl
static bool curl_fetch(const std::string &url, const std::string &dest) {
    std::string cmd = "curl -fsSL -o \"" + dest + "\" \"" + url + "\"";
    return system(cmd.c_str()) == 0;
}

// Given a package atom like "dev-libs/glib", find the latest ebuild version
// by fetching the directory listing from GitHub API
static std::string fetch_latest_version(const std::string &category, const std::string &pkgname) {
    std::string api_url = "https://api.github.com/repos/gentoo/gentoo/contents/" +
                          category + "/" + pkgname;
    std::string tmp = "/tmp/gentoo_ls.json";

    std::string cmd = "curl -fsSL -H \"Accept: application/vnd.github.v3+json\" "
                      "-o \"" + tmp + "\" \"" + api_url + "\"";
    if (system(cmd.c_str()) != 0) return "";

    // Parse JSON for .ebuild files — just grep for the version
    std::ifstream f(tmp);
    std::string content((std::istreambuf_iterator<char>(f)), {});

    // Find all "name":"pkgname-VERSION.ebuild" entries
    std::string best_ver;
    size_t pos = 0;
    std::string search = pkgname + "-";
    while ((pos = content.find(search, pos)) != std::string::npos) {
        size_t end = content.find(".ebuild", pos);
        if (end == std::string::npos) { pos++; continue; }
        std::string ver = content.substr(pos + search.size(), end - pos - search.size());
        // Simple string comparison — good enough for "latest"
        if (best_ver.empty() || ver > best_ver)
            best_ver = ver;
        pos = end;
    }
    return best_ver;
}

// Download a specific ebuild from Gentoo GitHub
// Returns path to downloaded file, or "" on failure
std::string fetch_ebuild(const std::string &atom) {
    // atom format: "category/pkgname" or "category/pkgname-VERSION"
    size_t slash = atom.find('/');
    if (slash == std::string::npos) {
        std::cerr << "[ebuild2pkg] Invalid atom: " << atom << std::endl;
        return "";
    }

    std::string category = atom.substr(0, slash);
    std::string rest     = atom.substr(slash + 1);

    // Strip slot
    size_t colon = rest.find(':');
    if (colon != std::string::npos) rest = rest.substr(0, colon);

    std::string pkgname, version;

    // Check if version is embedded in atom
    std::string::size_type dash = rest.rfind('-');
    if (dash != std::string::npos && isdigit(rest[dash + 1])) {
        pkgname = rest.substr(0, dash);
        version = rest.substr(dash + 1);
    } else {
        pkgname = rest;
        version = fetch_latest_version(category, pkgname);
        if (version.empty()) {
            std::cerr << "[ebuild2pkg] Could not find version for " << atom << std::endl;
            return "";
        }
    }

    std::string filename = pkgname + "-" + version + ".ebuild";
    std::string url = std::string(GENTOO_GITHUB) + "/" + category + "/" + pkgname + "/" + filename;
    std::string dest = "/tmp/ebuild2pkg_" + pkgname + "-" + version + ".ebuild";

    std::cout << "[ebuild2pkg] Fetching " << url << std::endl;
    if (!curl_fetch(url, dest)) {
        std::cerr << "[ebuild2pkg] Failed to fetch ebuild for " << atom << std::endl;
        return "";
    }

    return dest;
}

// Query Arch Linux package repos for a package name.
// Returns the Arch package name if found (may differ slightly), or "" if not found.
// Checks official repos first, then AUR.
std::string arch_lookup(const std::string &pkgname) {
    // Official repos
    std::string url = "https://archlinux.org/packages/search/json/?name=" + pkgname;
    std::string tmp = "/tmp/arch_pkg.json";
    std::string cmd = "curl -fsSL -o \"" + tmp + "\" \"" + url + "\"";
    if (system(cmd.c_str()) == 0) {
        std::ifstream f(tmp);
        std::string content((std::istreambuf_iterator<char>(f)), {});
        // If results array is non-empty, package exists
        size_t pos = content.find("\"results\":");
        if (pos != std::string::npos) {
            size_t bracket = content.find('[', pos);
            size_t close   = content.find(']', bracket);
            if (bracket != std::string::npos && close != std::string::npos && close > bracket + 1) {
                // Extract "pkgname":"..." from first result
                size_t np = content.find("\"pkgname\":", bracket);
                if (np != std::string::npos && np < close) {
                    size_t qs = content.find('"', np + 10) + 1;
                    size_t qe = content.find('"', qs);
                    if (qs != std::string::npos && qe != std::string::npos)
                        return content.substr(qs, qe - qs);
                }
            }
        }
    }

    // AUR fallback
    url = "https://aur.archlinux.org/rpc/v5/search/" + pkgname + "?by=name";
    cmd = "curl -fsSL -o \"" + tmp + "\" \"" + url + "\"";
    if (system(cmd.c_str()) == 0) {
        std::ifstream f(tmp);
        std::string content((std::istreambuf_iterator<char>(f)), {});
        // Look for exact name match in results
        std::string needle = "\"Name\":\"" + pkgname + "\"";
        if (content.find(needle) != std::string::npos)
            return pkgname;
        // Partial: return first result name
        size_t np = content.find("\"Name\":\"");
        if (np != std::string::npos) {
            size_t qs = np + 8;
            size_t qe = content.find('"', qs);
            if (qe != std::string::npos) {
                std::string found = content.substr(qs, qe - qs);
                std::cerr << "[ebuild2pkg] AUR fuzzy match: '" << pkgname
                          << "' -> '" << found << "'\n";
                return found;
            }
        }
    }

    return "";
}

// Determine Gentoo category for a bare package name using GitHub search API
std::string find_category(const std::string &pkgname) {
    std::string api = "https://api.github.com/search/code?q=" + pkgname +
                      "+in:path+extension:ebuild+repo:gentoo/gentoo";
    std::string tmp = "/tmp/gentoo_search.json";
    std::string cmd = "curl -fsSL -H \"Accept: application/vnd.github.v3+json\" "
                      "-o \"" + tmp + "\" \"" + api + "\"";
    if (system(cmd.c_str()) != 0) return "";

    std::ifstream f(tmp);
    std::string content((std::istreambuf_iterator<char>(f)), {});

    // Look for "path":"CATEGORY/pkgname/..."
    std::string search = "\"path\":\"";
    size_t pos = content.find(search);
    if (pos == std::string::npos) return "";
    pos += search.size();
    size_t slash = content.find('/', pos);
    if (slash == std::string::npos) return "";
    return content.substr(pos, slash - pos);
}