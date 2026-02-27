#include "ebuild.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <algorithm>
#include <filesystem>

namespace fs = std::filesystem;

// ── Version comparison ────────────────────────────────────────────────────────
//
// Splits "1.2.3p1" into numeric and suffix components and compares
// component-by-component.  Returns -1/0/1 like strcmp.
// Handles: 1.2.3, 6.18.4, 9.9p1, 2.11, 23.10, 0.18.0_rc1
//
static int compare_versions(const std::string &a, const std::string &b) {
    // Split into dot-separated components
    auto split = [](const std::string &s) {
        std::vector<std::string> parts;
        std::string cur;
        for (char c : s) {
            if (c == '.') {
                if (!cur.empty()) { parts.push_back(cur); cur.clear(); }
            } else {
                cur += c;
            }
        }
        if (!cur.empty()) parts.push_back(cur);
        return parts;
    };

    auto pa = split(a);
    auto pb = split(b);
    size_t n = std::max(pa.size(), pb.size());
    for (size_t i = 0; i < n; i++) {
        std::string sa = i < pa.size() ? pa[i] : "0";
        std::string sb = i < pb.size() ? pb[i] : "0";

        // Split each component into leading digits and trailing suffix
        // e.g. "9p1" -> num=9, suf="p1"
        //      "3"   -> num=3, suf=""
        auto split_num_suf = [](const std::string &s) -> std::pair<long long, std::string> {
            size_t i = 0;
            while (i < s.size() && isdigit((unsigned char)s[i])) i++;
            long long num = (i > 0) ? std::stoll(s.substr(0, i)) : 0;
            return { num, s.substr(i) };
        };

        auto [na, sufa] = split_num_suf(sa);
        auto [nb, sufb] = split_num_suf(sb);

        if (na != nb) return na < nb ? -1 : 1;
        if (sufa != sufb) return sufa < sufb ? -1 : 1;
    }
    return 0;
}

// ── Index entry ───────────────────────────────────────────────────────────────

struct IndexEntry {
    std::string rel_path;   // e.g. "libs/wlroots0.18-0.18.0.pkg"
    std::string pkg_name;   // e.g. "wlroots0.18"
    std::string version;    // e.g. "0.18.0"  (read from the .pkg file)
};

// ── PackageIndex ──────────────────────────────────────────────────────────────

// Reads the INDEX file from the repo root.
// Provides fast lookup of existing packages by name.
// Tracks new entries that need to be added when update() is called.
class PackageIndex {
public:
    std::string repo_root;
    std::string index_path;

    // Load the INDEX and read version info from each .pkg file
    bool load(const std::string &root) {
        repo_root  = root;
        index_path = root + "/INDEX";

        std::ifstream f(index_path);
        if (!f.is_open()) {
            // No INDEX yet — that's fine, we'll create one
            std::cout << "[ebuild2pkg] No INDEX found at " << index_path
                      << " — will create it\n";
            return true;
        }

        std::string line;
        while (std::getline(f, line)) {
            // Strip whitespace
            while (!line.empty() && (line.back() == '\r' || line.back() == ' '))
                line.pop_back();
            if (line.empty()) continue;

            IndexEntry e;
            e.rel_path = line;

            // pkg_name: filename without path and without -VERSION.pkg
            fs::path p(line);
            std::string fname = p.filename().string();   // e.g. wlroots0.18-0.18.0.pkg
            if (fname.size() > 4 && fname.substr(fname.size() - 4) == ".pkg")
                fname = fname.substr(0, fname.size() - 4);

            // Split name-version: last dash before a digit
            size_t dash = fname.rfind('-');
            while (dash != std::string::npos && dash > 0 && !isdigit((unsigned char)fname[dash + 1]))
                dash = fname.rfind('-', dash - 1);

            if (dash != std::string::npos && isdigit((unsigned char)fname[dash + 1])) {
                e.pkg_name = fname.substr(0, dash);
                e.version  = fname.substr(dash + 1);
            } else {
                e.pkg_name = fname;
                e.version  = "0";
            }

            // Cross-check version by reading the actual .pkg file
            std::string full_path = root + "/" + line;
            if (fs::exists(full_path)) {
                std::ifstream pf(full_path);
                std::string pline;
                while (std::getline(pf, pline)) {
                    if (pline.substr(0, 10) == "version = ") {
                        std::string v = pline.substr(10);
                        // Strip quotes
                        if (!v.empty() && v[0] == '"') v = v.substr(1);
                        if (!v.empty() && v.back() == '"') v.pop_back();
                        if (!v.empty()) e.version = v;
                        break;
                    }
                }
            }

            by_name_[e.pkg_name] = entries_.size();
            entries_.push_back(e);
        }

        std::cout << "[ebuild2pkg] INDEX loaded: " << entries_.size() << " packages\n";
        return true;
    }

    // Returns true if this package is already in the index at the same or newer version.
    // Sets out_action to "skip", "update", or "add".
    bool check(const std::string &pkg_name, const std::string &new_version,
               std::string &out_action) const {
        auto it = by_name_.find(pkg_name);
        if (it == by_name_.end()) {
            out_action = "add";
            return false;
        }
        const IndexEntry &e = entries_[it->second];
        int cmp = compare_versions(new_version, e.version);
        if (cmp <= 0) {
            out_action = "skip";
            return true;
        }
        out_action = "update";
        return false;
    }

    // Record that we wrote pkg_name-version.pkg at rel_path.
    // If the package was already in the index, updates the entry.
    // If it's new, queues it for addition.
    void record(const std::string &pkg_name, const std::string &version,
                const std::string &rel_path) {
        auto it = by_name_.find(pkg_name);
        if (it != by_name_.end()) {
            // Update existing entry in-place
            entries_[it->second].version  = version;
            entries_[it->second].rel_path = rel_path;
        } else {
            IndexEntry e;
            e.pkg_name = pkg_name;
            e.version  = version;
            e.rel_path = rel_path;
            by_name_[pkg_name] = entries_.size();
            entries_.push_back(e);
            new_entries_.push_back(rel_path);
        }
    }

    // Write the updated INDEX back to disk.
    // Preserves original entry order; appends new entries at the end.
    bool save() const {
        if (repo_root.empty()) return false;

        std::ofstream f(index_path);
        if (!f.is_open()) {
            std::cerr << "[ebuild2pkg] Cannot write INDEX: " << index_path << "\n";
            return false;
        }

        for (const auto &e : entries_)
            f << e.rel_path << "\n";

        if (!new_entries_.empty())
            std::cout << "[ebuild2pkg] INDEX: added " << new_entries_.size()
                      << " new entries\n";

        return true;
    }

    // Returns all rel_paths that were written this run (new + updated)
    std::vector<std::string> written_paths() const {
        std::vector<std::string> out;
        for (const auto &e : entries_) {
            for (const auto &np : new_entries_)
                if (np == e.rel_path) { out.push_back(e.rel_path); goto next; }
            // Also include updated entries (where rel_path changed)
            for (const auto &up : updated_paths_)
                if (up == e.rel_path) { out.push_back(e.rel_path); goto next; }
            next:;
        }
        return out;
    }

    void mark_updated(const std::string &rel_path) {
        updated_paths_.push_back(rel_path);
    }

    const std::vector<std::string> &new_entries() const { return new_entries_; }
    const std::vector<std::string> &updated_paths() const { return updated_paths_; }

private:
    std::vector<IndexEntry>             entries_;
    std::map<std::string, size_t>       by_name_;
    std::vector<std::string>            new_entries_;
    std::vector<std::string>            updated_paths_;
};
