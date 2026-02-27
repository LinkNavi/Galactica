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

// index.cpp
class PackageIndex {
public:
    std::string repo_root;
    std::string index_path;
    bool load(const std::string &root);
    bool check(const std::string &pkg_name, const std::string &new_version,
               std::string &out_action) const;
    void record(const std::string &pkg_name, const std::string &version,
                const std::string &rel_path);
    bool save() const;
    void mark_updated(const std::string &rel_path);
    const std::vector<std::string> &new_entries() const;
    const std::vector<std::string> &updated_paths() const;
private:
    struct IndexEntry { std::string rel_path, pkg_name, version; };
    std::vector<IndexEntry>         entries_;
    std::map<std::string, size_t>   by_name_;
    std::vector<std::string>        new_entries_;
    std::vector<std::string>        updated_paths_;
};

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
    if (gentoo_cat == "app-admin")                                  return "system";
    if (gentoo_cat == "sec-policy")                                 return "security";
    if (gentoo_cat == "sys-auth")                                   return "system";
    return "misc";
}

// Extract pkgname and version from an atom string like "app-admin/sudo" or
// ">=dev-libs/glib-2.0:2". Returns {pkgname, version} where version may be "".
static std::pair<std::string,std::string> atom_to_name_ver(const std::string &atom) {
    std::string s = atom;

    // Strip leading version operators
    size_t i = 0;
    while (i < s.size() && (s[i] == '>' || s[i] == '<' || s[i] == '=' ||
                             s[i] == '!' || s[i] == '~'))
        i++;
    s = s.substr(i);

    // Strip slot
    size_t colon = s.find(':');
    if (colon != std::string::npos) s = s.substr(0, colon);

    // Strip USE flags
    size_t bracket = s.find('[');
    if (bracket != std::string::npos) s = s.substr(0, bracket);

    // Get the part after category/
    size_t slash = s.rfind('/');
    std::string rest = (slash != std::string::npos) ? s.substr(slash + 1) : s;

    // Split name-version: last dash before digit
    size_t dash = rest.rfind('-');
    while (dash != std::string::npos && dash > 0 &&
           !isdigit((unsigned char)rest[dash + 1]))
        dash = rest.rfind('-', dash - 1);

    if (dash != std::string::npos && isdigit((unsigned char)rest[dash + 1])) {
        return { rest.substr(0, dash), rest.substr(dash + 1) };
    }
    return { rest, "" };
}

struct ConvertOptions {
    std::string outdir      = ".";
    std::string category;
    bool        recursive   = false;
    int         max_depth   = 3;
    std::string repo_root;
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

static bool should_convert(const std::string &pkg_name, const std::string &version,
                           bool &is_update) {
    is_update = false;
    if (!g_index) return true;
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

static void convert_atom(const std::string &atom,
                         const ConvertOptions &opts, int depth);
static void convert_file(const std::string &filepath,
                         const std::string &gentoo_cat,
                         const std::string &pkg_name_hint,
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

    // Skip empty pkg names (mapped to "skip")
    if (dr.pkg_name.empty()) return;

    std::cout << "[ebuild2pkg] Generating .pkg for dep '"
              << dr.pkg_name << "' (atom: " << dr.gentoo_atom << ")\n";

    std::string ebuild_path = fetch_ebuild(dr.gentoo_atom);
    if (!ebuild_path.empty()) {
        std::string gentoo_cat;
        size_t slash = dr.gentoo_atom.find('/');
        if (slash != std::string::npos)
            gentoo_cat = dr.gentoo_atom.substr(0, slash);
        // Pass the dep's pkg_name as a hint so the file gets named correctly
        convert_file(ebuild_path, gentoo_cat, dr.pkg_name, opts, depth);
    } else {
        std::cerr << "[ebuild2pkg] No ebuild for '" << dr.pkg_name
                  << "' — writing stub\n";
        write_stub(dr, opts);
    }
}

// ── Core conversion ───────────────────────────────────────────────────────────

static void convert_file(const std::string &filepath,
                         const std::string &gentoo_cat,
                         const std::string &pkg_name_hint,
                         const ConvertOptions &opts, int depth) {
    // Parse with name hint so we don't get the temp filename
    Ebuild eb = parse_ebuild_file(filepath, pkg_name_hint, "");
    if (eb.name.empty()) {
        std::cerr << "[ebuild2pkg] Failed to parse: " << filepath << "\n";
        return;
    }

    // Override name with hint if the parsed name looks like a temp path artifact
    if (!pkg_name_hint.empty() &&
        (eb.name.find("ebuild2pkg_") != std::string::npos ||
         eb.name.find("tmp_") != std::string::npos)) {
        eb.name = pkg_name_hint;
    }

    if (converted.count(eb.name)) return;

    bool is_update;
    if (!should_convert(eb.name, eb.version, is_update)) {
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

    for (const auto &dr : result.pending)
        process_pending(dr, opts, depth + 1);

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

    std::string gentoo_cat, pkgname;
    size_t slash = atom.find('/');
    if (slash != std::string::npos) {
        gentoo_cat = atom.substr(0, slash);
        std::string rest = atom.substr(slash + 1);
        // Strip slot
        size_t c = rest.find(':');
        if (c != std::string::npos) rest = rest.substr(0, c);
        // Get just the package name (no version)
        auto [name, ver] = atom_to_name_ver(atom);
        pkgname = name;
    } else {
        pkgname = atom;
    }

    if (pkgname.empty() || converted.count(pkgname)) return;

    std::string ebuild_path = fetch_ebuild(atom);
    if (ebuild_path.empty()) {
        std::cerr << "[ebuild2pkg] Skipping " << atom << " (fetch failed)\n";
        return;
    }
    convert_file(ebuild_path, gentoo_cat, pkgname, opts, depth);
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
        // Infer name from local ebuild filename properly
        std::string fname = p.stem().string();  // e.g. "sudo-9999"
        auto [name, ver] = atom_to_name_ver(fname);
        convert_file(input, gentoo_cat, name, opts, 0);
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
        if (!git_commit_and_push(opts.repo_root, g_written_paths,
                                 "INDEX", opts.branch)) {
            std::cerr << "[ebuild2pkg] Git commit/push failed\n";
            return 1;
        }
    }

    return 0;
}
