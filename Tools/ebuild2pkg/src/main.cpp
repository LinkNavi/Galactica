#include "index.h"
#include "ebuild.h"
#include <filesystem>
#include <iostream>
#include <set>
#include <string>
#include <vector>

namespace fs = std::filesystem;

// ── Forward declarations ──────────────────────────────────────────────────────

Ebuild      parse_ebuild_file(const std::string &filepath,
                              const std::string &name, const std::string &ver);
std::string fetch_ebuild(const std::string &atom);
std::string find_category(const std::string &pkgname);
bool        write_pkg_file(const PkgFile &pkg, const std::string &outpath);

struct ConvertResult {
    PkgFile              pkg;
    std::vector<DepResult> pending;
};
ConvertResult ebuild_to_pkg(const Ebuild &eb, const std::string &category);




// git.cpp
bool git_commit_and_push(const std::string              &repo_root,
                         const std::vector<std::string> &changed_relpaths,
                         const std::string              &index_relpath,
                         const std::string              &branch);

// ── Helpers ───────────────────────────────────────────────────────────────────

static void print_usage(const char *argv0) {
    std::cerr
        << "Usage:\n"
        << "  " << argv0 << " <file.ebuild> [options]\n"
        << "  " << argv0 << " --fetch <atom> [options]\n"
        << "\nOptions:\n"
        << "  -o <outdir>      Output directory for .pkg files (default: .)\n"
        << "  -c <category>    Override category (default: auto)\n"
        << "  -r               Recurse into all deps including Arch-official ones\n"
        << "  --depth <N>      Max recursion depth (default: 3)\n"
        << "  --repo <path>    Repo root to read/update INDEX (enables index check)\n"
        << "  --commit         Auto git-add/commit/push after conversion (requires --repo)\n"
        << "  --branch <name>  Branch to push to (default: main)\n"
        << "  --dry-run        Show what would be done without writing files\n"
        << "\nIndex behaviour (when --repo is set):\n"
        << "  Packages already in INDEX at same version are skipped.\n"
        << "  Packages at older version are regenerated.\n"
        << "  New packages are added and INDEX is updated.\n"
        << "\nExamples:\n"
        << "  " << argv0 << " --fetch gui-libs/wlroots -o libs/ --repo . --commit\n"
        << "  " << argv0 << " wlroots-0.18.0.ebuild -o libs/ --repo .\n";
}

static std::string infer_category(const std::string &gentoo_cat) {
    if (gentoo_cat == "x11-libs"    || gentoo_cat == "gui-libs"
        || gentoo_cat == "dev-libs" || gentoo_cat == "sys-libs"
        || gentoo_cat == "net-libs" || gentoo_cat == "media-libs") return "libs";
    if (gentoo_cat == "x11-apps"    || gentoo_cat == "x11-wm"
        || gentoo_cat == "gui-apps")                               return "desktop";
    if (gentoo_cat == "media-video" || gentoo_cat == "media-sound") return "media";
    if (gentoo_cat == "net-misc"    || gentoo_cat == "net-p2p")     return "network";
    if (gentoo_cat == "sys-apps"    || gentoo_cat == "sys-fs")      return "system";
    if (gentoo_cat == "app-editors")                                return "editors";
    return "misc";
}

struct ConvertOptions {
    std::string outdir      = ".";
    std::string category;
    bool        recursive   = false;
    int         max_depth   = 3;
    // repo / git options
    std::string repo_root;    // "" means no index check
    bool        do_commit   = false;
    std::string branch      = "main";
    bool        dry_run     = false;
};

// Global visited set — prevents cycles
static std::set<std::string>  converted;
// Global index — nullptr if --repo not set
static PackageIndex           *g_index = nullptr;
// All pkg files written this run (repo-relative paths)
static std::vector<std::string> g_written_paths;

// ── Index helpers ─────────────────────────────────────────────────────────────

// Returns the repo-relative path for a pkg file.
// e.g. outdir="/repos/Galactica/libs", repo_root="/repos/Galactica",
//      filename="wlroots0.18-0.18.0.pkg"  =>  "libs/wlroots0.18-0.18.0.pkg"
static std::string make_rel_path(const std::string &outdir,
                                 const std::string &repo_root,
                                 const std::string &filename) {
    if (repo_root.empty()) return filename;
    fs::path out(outdir);
    fs::path repo(repo_root);
    try {
        return fs::relative(out / filename, repo).string();
    } catch (...) {
        return filename;
    }
}

// Check whether we should generate a package, and if so, tell us why.
// Returns false if we should skip.
static bool should_convert(const std::string &pkg_name, const std::string &version,
                           bool &is_update) {
    is_update = false;
    if (!g_index) return true;   // no index — always convert
    std::string action;
    bool present = g_index->check(pkg_name, version, action);
    if (action == "skip") {
        std::cout << "[ebuild2pkg] " << pkg_name << "-" << version
                  << " already in INDEX, skipping\n";
        return false;
    }
    if (action == "update") {
        std::cout << "[ebuild2pkg] " << pkg_name << " has newer version "
                  << version << " — regenerating\n";
        is_update = true;
    }
    return true;
}

// Forward declarations for mutual recursion
static void convert_atom(const std::string &atom,
                         const ConvertOptions &opts, int depth);
static void convert_file(const std::string &filepath,
                         const std::string &gentoo_cat,
                         const ConvertOptions &opts, int depth);

// ── Stub generation ───────────────────────────────────────────────────────────

static void write_stub(const DepResult &dr, const ConvertOptions &opts) {
    bool is_update;
    if (!should_convert(dr.pkg_name, "0.0.0", is_update)) return;

    PkgFile stub;
    stub.name        = dr.pkg_name;
    stub.version     = "0.0.0";
    stub.description = dr.pkg_name + " (stub — fill in manually)";
    stub.url         = "";
    stub.category    = "misc";
    stub.install_script =
        "# TODO: fill in install script for " + dr.pkg_name + "\n"
        "# No ebuild or Arch package was found.\n"
        "# Possible sources:\n"
        "#   AUR:    https://aur.archlinux.org/packages/" + dr.pkg_name + "\n"
        "#   GitHub: https://github.com/search?q=" + dr.pkg_name + "\n";

    std::string filename = dr.pkg_name + "-0.0.0.pkg";
    std::string outpath  = opts.outdir + "/" + filename;

    if (opts.dry_run) {
        std::cout << "[dry-run] Would write stub: " << outpath << "\n";
        converted.insert(dr.pkg_name);
        return;
    }

    write_pkg_file(stub, outpath);
    converted.insert(dr.pkg_name);

    if (g_index) {
        std::string rel = make_rel_path(opts.outdir, opts.repo_root, filename);
        g_index->record(dr.pkg_name, "0.0.0", rel);
        if (is_update) g_index->mark_updated(rel);
        g_written_paths.push_back(rel);
    }
}

// ── Pending dep processing ────────────────────────────────────────────────────

static void process_pending(const DepResult &dr,
                            const ConvertOptions &opts, int depth) {
    if (converted.count(dr.pkg_name)) return;

    std::cout << "[ebuild2pkg] Generating .pkg for dep '"
              << dr.pkg_name << "' (atom: " << dr.gentoo_atom << ")\n";

    std::string ebuild_path = fetch_ebuild(dr.gentoo_atom);
    if (!ebuild_path.empty()) {
        std::string gentoo_cat;
        size_t slash = dr.gentoo_atom.find('/');
        if (slash != std::string::npos)
            gentoo_cat = dr.gentoo_atom.substr(0, slash);
        convert_file(ebuild_path, gentoo_cat, opts, depth);
    } else {
        std::cerr << "[ebuild2pkg] No ebuild for '" << dr.pkg_name
                  << "' — writing stub\n";
        write_stub(dr, opts);
    }
}

// ── Core conversion ───────────────────────────────────────────────────────────

static void convert_file(const std::string &filepath,
                         const std::string &gentoo_cat,
                         const ConvertOptions &opts, int depth) {
    Ebuild eb = parse_ebuild_file(filepath, "", "");
    if (eb.name.empty()) {
        std::cerr << "[ebuild2pkg] Failed to parse: " << filepath << "\n";
        return;
    }

    if (converted.count(eb.name)) return;

    // ── Index check ───────────────────────────────────────────────────
    bool is_update;
    if (!should_convert(eb.name, eb.version, is_update)) {
        // Even if we skip this package, we still need to mark it visited
        // so we don't loop back into it through dep chains.
        converted.insert(eb.name);
        return;
    }
    converted.insert(eb.name);

    std::string cat = opts.category.empty() ? infer_category(gentoo_cat) : opts.category;
    ConvertResult result = ebuild_to_pkg(eb, cat);

    std::string filename = eb.name + "-" + eb.version + ".pkg";
    std::string outpath  = opts.outdir + "/" + filename;

    if (opts.dry_run) {
        std::cout << "[dry-run] Would write: " << outpath << "\n";
    } else {
        write_pkg_file(result.pkg, outpath);
    }

    // Record in index
    if (g_index && !opts.dry_run) {
        std::string rel = make_rel_path(opts.outdir, opts.repo_root, filename);
        g_index->record(eb.name, eb.version, rel);
        if (is_update) g_index->mark_updated(rel);
        g_written_paths.push_back(rel);
    }

    if (depth >= opts.max_depth) {
        if (!result.pending.empty())
            std::cerr << "[ebuild2pkg] Max depth — skipping "
                      << result.pending.size() << " pending dep(s) for "
                      << eb.name << "\n";
        return;
    }

    // ── AUR / not-found deps — always recurse ─────────────────────────
    for (const auto &dr : result.pending)
        process_pending(dr, opts, depth + 1);

    // ── -r: also recurse into Arch-official deps ──────────────────────
    if (opts.recursive) {
        std::set<std::string> handled;
        for (const auto &dr : result.pending) handled.insert(dr.gentoo_atom);

        for (const auto &atom : eb.rdepend) {
            if (handled.count(atom)) continue;
            if (GENTOO_TO_GALACTICA.count(atom)) continue;
            std::string no_slot = atom;
            size_t c = no_slot.rfind(':');
            if (c != std::string::npos) no_slot = no_slot.substr(0, c);
            if (GENTOO_TO_GALACTICA.count(no_slot)) continue;
            convert_atom(atom, opts, depth + 1);
        }
    }
}

static void convert_atom(const std::string &atom,
                         const ConvertOptions &opts, int depth) {
    if (depth > opts.max_depth) return;

    std::string gentoo_cat, pkgname = atom;
    size_t slash = atom.find('/');
    if (slash != std::string::npos) {
        gentoo_cat = atom.substr(0, slash);
        pkgname    = atom.substr(slash + 1);
        size_t c   = pkgname.find(':');
        if (c != std::string::npos) pkgname = pkgname.substr(0, c);
    }
    if (converted.count(pkgname)) return;

    std::string ebuild_path = fetch_ebuild(atom);
    if (ebuild_path.empty()) {
        std::cerr << "[ebuild2pkg] Skipping " << atom << " (fetch failed)\n";
        return;
    }
    convert_file(ebuild_path, gentoo_cat, opts, depth);
}

// ── Entry point ───────────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    if (argc < 2) { print_usage(argv[0]); return 1; }

    ConvertOptions opts;
    bool fetch_mode = false;
    std::string input;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if      (a == "-o"        && i + 1 < argc) opts.outdir    = argv[++i];
        else if (a == "-c"        && i + 1 < argc) opts.category  = argv[++i];
        else if (a == "--depth"   && i + 1 < argc) opts.max_depth = std::stoi(argv[++i]);
        else if (a == "--repo"    && i + 1 < argc) opts.repo_root = argv[++i];
        else if (a == "--branch"  && i + 1 < argc) opts.branch    = argv[++i];
        else if (a == "-r")                         opts.recursive = true;
        else if (a == "--fetch")                    fetch_mode     = true;
        else if (a == "--commit")                   opts.do_commit = true;
        else if (a == "--dry-run")                  opts.dry_run   = true;
        else if (a[0] != '-')                       input          = a;
        else { std::cerr << "Unknown option: " << a << "\n"; return 1; }
    }

    if (input.empty()) { print_usage(argv[0]); return 1; }

    if (opts.do_commit && opts.repo_root.empty()) {
        std::cerr << "[ebuild2pkg] --commit requires --repo <path>\n";
        return 1;
    }

    // ── Load index ────────────────────────────────────────────────────
    PackageIndex index;
    if (!opts.repo_root.empty()) {
        if (!index.load(opts.repo_root)) {
            std::cerr << "[ebuild2pkg] Failed to load INDEX from "
                      << opts.repo_root << "\n";
            return 1;
        }
        g_index = &index;
    }

    fs::create_directories(opts.outdir);

    // ── Convert ───────────────────────────────────────────────────────
    if (fetch_mode) {
        convert_atom(input, opts, 0);
    } else {
        std::string gentoo_cat;
        fs::path p(input);
        if (p.has_parent_path()) {
            fs::path gp = p.parent_path().parent_path();
            if (!gp.empty()) gentoo_cat = gp.filename().string();
        }
        convert_file(input, gentoo_cat, opts, 0);
    }

    std::cout << "[ebuild2pkg] Done. "
              << converted.size() << " package(s) processed, "
              << g_written_paths.size() << " written.\n";

    // ── Save index ────────────────────────────────────────────────────
    if (g_index && !opts.dry_run && !g_written_paths.empty()) {
        if (!index.save()) {
            std::cerr << "[ebuild2pkg] Failed to save INDEX\n";
            return 1;
        }
    }

    // ── Git commit ────────────────────────────────────────────────────
    if (opts.do_commit && !opts.dry_run) {
        // Include the INDEX file itself in the commit
        if (!git_commit_and_push(opts.repo_root, g_written_paths,
                                 "INDEX", opts.branch)) {
            std::cerr << "[ebuild2pkg] Git commit/push failed\n";
            return 1;
        }
    }

    return 0;
}
