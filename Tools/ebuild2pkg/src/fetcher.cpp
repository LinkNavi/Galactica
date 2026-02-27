#include "ebuild.h"
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <filesystem>
#include <sstream>
#include <regex>

namespace fs = std::filesystem;

static const char *GENTOO_GITHUB = "https://raw.githubusercontent.com/gentoo/gentoo/master";

static bool curl_fetch(const std::string &url, const std::string &dest) {
    std::string cmd = "curl -fsSL -o \"" + dest + "\" \"" + url + "\"";
    return system(cmd.c_str()) == 0;
}

// Strip Gentoo bash variables like ${PV}, ${P}, ${PN} from an atom/version string
static std::string strip_bash_vars(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        if (s[i] == '$' && i + 1 < s.size() && s[i+1] == '{') {
            size_t end = s.find('}', i + 2);
            if (end != std::string::npos) {
                i = end + 1;
                continue;
            }
        }
        out += s[i++];
    }
    return out;
}

// Convert a Gentoo package name to likely Arch name
// e.g. "openldap-2.1.30-r1" -> "openldap", "fts-standalone" -> "fts"
static std::string gentoo_to_arch_name(const std::string &pkgname) {
    // Strip -rN revision suffix
    std::string name = pkgname;
    {
        std::regex rev_re("-r\\d+$");
        name = std::regex_replace(name, rev_re, "");
    }
    // Strip trailing version like -2.1.30
    {
        std::regex ver_re("-\\d[\\d.]*$");
        name = std::regex_replace(name, ver_re, "");
    }
    // Common Gentoo->Arch name mappings
    static const std::map<std::string, std::string> name_map = {
        {"openldap",         "openldap"},
        {"libselinux",       "libselinux"},
        {"libsepol",         "libsepol"},
        {"fts-standalone",   "musl-fts"},
        {"editor-wrapper",   ""},   // skip - Arch has no equivalent
        {"skey",             ""},   // skip - obsolete
    };
    auto it = name_map.find(name);
    if (it != name_map.end()) return it->second;
    return name;
}

static std::string fetch_latest_version(const std::string &category, const std::string &pkgname) {
    std::string api_url = "https://api.github.com/repos/gentoo/gentoo/contents/" +
                          category + "/" + pkgname;
    std::string tmp = "/tmp/ebuild2pkg_ls_" + pkgname + ".json";

    std::string cmd = "curl -fsSL -H \"Accept: application/vnd.github.v3+json\" "
                      "-o \"" + tmp + "\" \"" + api_url + "\"";
    if (system(cmd.c_str()) != 0) return "";

    std::ifstream f(tmp);
    std::string content((std::istreambuf_iterator<char>(f)), {});

    std::string best_ver;
    size_t pos = 0;
    std::string search = pkgname + "-";
    while ((pos = content.find(search, pos)) != std::string::npos) {
        size_t end = content.find(".ebuild", pos);
        if (end == std::string::npos) { pos++; continue; }
        std::string ver = content.substr(pos + search.size(), end - pos - search.size());
        // Skip 9999 (live ebuilds) unless it's the only option
        if (ver != "9999" && (best_ver.empty() || ver > best_ver))
            best_ver = ver;
        pos = end;
    }
    // Fallback to 9999 if nothing else found
    if (best_ver.empty()) {
        pos = 0;
        while ((pos = content.find(search, pos)) != std::string::npos) {
            size_t end = content.find(".ebuild", pos);
            if (end == std::string::npos) { pos++; continue; }
            std::string ver = content.substr(pos + search.size(), end - pos - search.size());
            if (best_ver.empty() || ver > best_ver)
                best_ver = ver;
            pos = end;
        }
    }
    return best_ver;
}

std::string fetch_ebuild(const std::string &atom_raw) {
    // Strip bash variables first
    std::string atom = strip_bash_vars(atom_raw);

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

    // Strip leading version operators
    size_t i = 0;
    while (i < rest.size() && (rest[i] == '>' || rest[i] == '<' || rest[i] == '=' || rest[i] == '!'))
        i++;
    rest = rest.substr(i);

    std::string pkgname, version;
    std::string::size_type dash = rest.rfind('-');
    if (dash != std::string::npos && isdigit((unsigned char)rest[dash + 1])) {
        pkgname = rest.substr(0, dash);
        version = rest.substr(dash + 1);
        // Strip bash vars from version too
        version = strip_bash_vars(version);
        // If version contains bash var remnants or is empty, fetch latest
        if (version.empty() || version.find('{') != std::string::npos ||
            version.find('$') != std::string::npos) {
            version = fetch_latest_version(category, pkgname);
        }
    } else {
        pkgname = rest;
        version = fetch_latest_version(category, pkgname);
        if (version.empty()) {
            std::cerr << "[ebuild2pkg] Could not find version for " << atom << std::endl;
            return "";
        }
    }

    std::string filename = pkgname + "-" + version + ".ebuild";
    std::string url  = std::string(GENTOO_GITHUB) + "/" + category + "/" + pkgname + "/" + filename;
    std::string dest = "/tmp/ebuild2pkg_" + pkgname + "-" + version + ".ebuild";

    std::cout << "[ebuild2pkg] Fetching " << url << std::endl;
    if (!curl_fetch(url, dest)) {
        std::cerr << "[ebuild2pkg] Failed to fetch ebuild for " << atom << std::endl;
        return "";
    }

    // Verify it's actually a valid ebuild (not a 404 HTML page)
    std::ifstream check(dest);
    std::string first_line;
    std::getline(check, first_line);
    if (first_line.find("<!DOCTYPE") != std::string::npos ||
        first_line.find("<html") != std::string::npos) {
        std::cerr << "[ebuild2pkg] Got HTML instead of ebuild for " << atom << std::endl;
        fs::remove(dest);
        return "";
    }

    return dest;
}

// arch_lookup: Check official Arch repos first, then AUR.
// Tries multiple name variants to improve hit rate.
ArchResult arch_lookup(const std::string &pkgname_raw) {
    // Normalize: strip bash vars, revision suffixes, version suffixes
    std::string pkgname = gentoo_to_arch_name(strip_bash_vars(pkgname_raw));

    // Empty means "skip this dep"
    if (pkgname.empty()) {
        return { "", ArchSource::NOT_FOUND };
    }

    // Build list of name variants to try (most specific first)
    std::vector<std::string> variants = { pkgname };

    // lib prefix variants
    if (pkgname.size() > 3 && pkgname.substr(0, 3) == "lib") {
        variants.push_back(pkgname.substr(3));  // try without lib prefix
    } else {
        variants.push_back("lib" + pkgname);    // try with lib prefix
    }

    // selinux packages are in Arch official
    if (pkgname == "libselinux" || pkgname == "libsepol" || pkgname == "libsemanage") {
        return { pkgname, ArchSource::OFFICIAL };
    }

    std::string tmp = "/tmp/ebuild2pkg_arch_" + pkgname + ".json";

    for (const auto &name : variants) {
        if (name.empty()) continue;

        // ── Official repos ─────────────────────────────────────────────
        {
            std::string url = "https://archlinux.org/packages/search/json/?name=" + name;
            std::string cmd = "curl -fsSL -o \"" + tmp + "\" \"" + url + "\"";
            if (system(cmd.c_str()) == 0) {
                std::ifstream f(tmp);
                std::string content((std::istreambuf_iterator<char>(f)), {});
                // Check results array is non-empty
                size_t pos = content.find("\"results\":");
                if (pos != std::string::npos) {
                    size_t bracket = content.find('[', pos);
                    size_t close   = content.find(']', bracket);
                    if (bracket != std::string::npos && close != std::string::npos
                        && close > bracket + 1) {
                        size_t np = content.find("\"pkgname\":", bracket);
                        if (np != std::string::npos && np < close) {
                            size_t qs = content.find('"', np + 10) + 1;
                            size_t qe = content.find('"', qs);
                            if (qs != std::string::npos && qe != std::string::npos) {
                                std::string found = content.substr(qs, qe - qs);
                                std::cout << "[ebuild2pkg] Official: '" << pkgname_raw
                                          << "' -> '" << found << "'\n";
                                return { found, ArchSource::OFFICIAL };
                            }
                        }
                    }
                }
            }
        }
    }

    // ── AUR (only try exact name, avoid fuzzy false positives) ─────────
    {
        std::string url = "https://aur.archlinux.org/rpc/v5/search/" + pkgname + "?by=name-desc";
        std::string cmd = "curl -fsSL -o \"" + tmp + "\" \"" + url + "\"";
        if (system(cmd.c_str()) == 0) {
            std::ifstream f(tmp);
            std::string content((std::istreambuf_iterator<char>(f)), {});

            // Only accept exact name match to avoid aacskeys-style false positives
            std::string needle = "\"Name\":\"" + pkgname + "\"";
            if (content.find(needle) != std::string::npos) {
                std::cerr << "[ebuild2pkg] AUR: '" << pkgname << "' (will generate .pkg)\n";
                return { pkgname, ArchSource::AUR };
            }
        }
    }

    return { "", ArchSource::NOT_FOUND };
}

std::string find_category(const std::string &pkgname) {
    std::string api = "https://api.github.com/search/code?q=" + pkgname +
                      "+in:path+extension:ebuild+repo:gentoo/gentoo";
    std::string tmp = "/tmp/ebuild2pkg_gcat_" + pkgname + ".json";
    std::string cmd = "curl -fsSL -H \"Accept: application/vnd.github.v3+json\" "
                      "-o \"" + tmp + "\" \"" + api + "\"";
    if (system(cmd.c_str()) != 0) return "";

    std::ifstream f(tmp);
    std::string content((std::istreambuf_iterator<char>(f)), {});

    std::string search = "\"path\":\"";
    size_t pos = content.find(search);
    if (pos == std::string::npos) return "";
    pos += search.size();
    size_t slash = content.find('/', pos);
    if (slash == std::string::npos) return "";
    return content.substr(pos, slash - pos);
}
