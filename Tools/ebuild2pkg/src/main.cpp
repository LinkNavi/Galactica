#include "ebuild.h"
#include <filesystem>
#include <iostream>
#include <set>
#include <string>
#include <vector>

namespace fs = std::filesystem;

// Forward declarations
Ebuild       parse_ebuild_file(const std::string &filepath, const std::string &name, const std::string &ver);
PkgFile      ebuild_to_pkg(const Ebuild &eb, const std::string &category);
bool         write_pkg_file(const PkgFile &pkg, const std::string &outpath);
std::string  fetch_ebuild(const std::string &atom);
std::string  find_category(const std::string &pkgname);
std::string  map_dep(const std::string &atom);

static void print_usage(const char *argv0) {
    std::cerr << "Usage:\n"
              << "  " << argv0 << " <file.ebuild> [options]      Convert local ebuild\n"
              << "  " << argv0 << " --fetch <atom> [options]     Fetch & convert from Gentoo\n"
              << "\nOptions:\n"
              << "  -o <outdir>     Output directory (default: .)\n"
              << "  -c <category>   Override pkg category (default: auto)\n"
              << "  -r              Recursively convert dependencies\n"
              << "  --depth <N>     Max recursion depth (default: 3, only with -r)\n"
              << "\nExamples:\n"
              << "  " << argv0 << " wlroots-0.18.0.ebuild -o ./packages\n"
              << "  " << argv0 << " --fetch gui-libs/wlroots -o ./packages -r\n"
              << "  " << argv0 << " --fetch dev-libs/json-c\n";
}

// Infer Galactica category from Gentoo category
static std::string infer_category(const std::string &gentoo_cat) {
    if (gentoo_cat == "x11-libs"    || gentoo_cat == "gui-libs")    return "libs";
    if (gentoo_cat == "dev-libs"    || gentoo_cat == "sys-libs")     return "libs";
    if (gentoo_cat == "media-libs")                                  return "libs";
    if (gentoo_cat == "net-libs")                                    return "libs";
    if (gentoo_cat == "x11-apps"    || gentoo_cat == "x11-wm")       return "desktop";
    if (gentoo_cat == "gui-apps")                                    return "desktop";
    if (gentoo_cat == "media-video" || gentoo_cat == "media-sound")  return "media";
    if (gentoo_cat == "net-misc"    || gentoo_cat == "net-p2p")      return "network";
    if (gentoo_cat == "sys-apps"    || gentoo_cat == "sys-fs")       return "system";
    if (gentoo_cat == "app-editors")                                 return "editors";
    return "misc";
}

struct ConvertOptions {
    std::string outdir      = ".";
    std::string category;
    bool        recursive   = false;
    int         max_depth   = 3;
};

static std::set<std::string> converted; // track to avoid cycles

static void convert_atom(const std::string &atom, const ConvertOptions &opts, int depth);

static void convert_file(const std::string &filepath, const std::string &gentoo_cat,
                         const ConvertOptions &opts, int depth) {
    Ebuild eb = parse_ebuild_file(filepath, "", "");
    if (eb.name.empty()) {
        std::cerr << "[ebuild2pkg] Failed to parse: " << filepath << std::endl;
        return;
    }

    if (converted.count(eb.name)) return;
    converted.insert(eb.name);

    std::string cat = opts.category.empty() ? infer_category(gentoo_cat) : opts.category;
    PkgFile pkg = ebuild_to_pkg(eb, cat);

    std::string outpath = opts.outdir + "/" + eb.name + "-" + eb.version + ".pkg";
    write_pkg_file(pkg, outpath);

    // Recurse into deps
    if (opts.recursive && depth < opts.max_depth) {
        std::cout << "[ebuild2pkg] Processing deps for " << eb.name
                  << " (depth " << depth << ")" << std::endl;
        for (const auto &dep_atom : eb.rdepend) {
            // Only recurse if not in our mapping table (i.e. not a known system pkg)
            std::string mapped = map_dep(dep_atom);
            if (mapped.empty()) continue;
            // If it's in the mapping table we assume it's already packaged
            if (GENTOO_TO_GALACTICA.count(dep_atom)) continue;
            convert_atom(dep_atom, opts, depth + 1);
        }
    }
}

static void convert_atom(const std::string &atom, const ConvertOptions &opts, int depth) {
    if (depth > opts.max_depth) return;

    // Parse category from atom
    std::string gentoo_cat;
    std::string pkgname = atom;
    size_t slash = atom.find('/');
    if (slash != std::string::npos) {
        gentoo_cat = atom.substr(0, slash);
        pkgname    = atom.substr(slash + 1);
        // Strip slot
        size_t colon = pkgname.find(':');
        if (colon != std::string::npos) pkgname = pkgname.substr(0, colon);
    }

    if (converted.count(pkgname)) return;

    std::string ebuild_path = fetch_ebuild(atom);
    if (ebuild_path.empty()) {
        std::cerr << "[ebuild2pkg] Skipping " << atom << " (fetch failed)" << std::endl;
        return;
    }
    convert_file(ebuild_path, gentoo_cat, opts, depth);
}

int main(int argc, char *argv[]) {
    if (argc < 2) { print_usage(argv[0]); return 1; }

    ConvertOptions opts;
    bool fetch_mode = false;
    std::string input;

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if      (arg == "-o"      && i + 1 < argc) opts.outdir    = argv[++i];
        else if (arg == "-c"      && i + 1 < argc) opts.category  = argv[++i];
        else if (arg == "--depth" && i + 1 < argc) opts.max_depth = std::stoi(argv[++i]);
        else if (arg == "-r")                       opts.recursive = true;
        else if (arg == "--fetch")                  fetch_mode = true;
        else if (arg[0] != '-')                     input = arg;
        else { std::cerr << "Unknown option: " << arg << std::endl; return 1; }
    }

    if (input.empty()) { print_usage(argv[0]); return 1; }

    // Create output dir
    fs::create_directories(opts.outdir);

    if (fetch_mode) {
        convert_atom(input, opts, 0);
    } else {
        // Local file
        std::string gentoo_cat;
        // Try to infer category from parent directory name
        fs::path p(input);
        if (p.has_parent_path()) {
            std::string parent = p.parent_path().filename().string();
            // Could be "category/pkgname" structure
            fs::path grandparent = p.parent_path().parent_path();
            if (!grandparent.empty())
                gentoo_cat = grandparent.filename().string();
        }
        convert_file(input, gentoo_cat, opts, 0);
    }

    std::cout << "[ebuild2pkg] Done. " << converted.size() << " package(s) converted." << std::endl;
    return 0;
}