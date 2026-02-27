#include "index.h"
#include <fstream>
#include <iostream>
#include <algorithm>
#include <filesystem>

namespace fs = std::filesystem;

// ── Version comparison ────────────────────────────────────────────────────────
static int compare_versions(const std::string &a, const std::string &b) {
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

// ── PackageIndex ──────────────────────────────────────────────────────────────

bool PackageIndex::load(const std::string &root) {
    repo_root  = root;
    index_path = root + "/INDEX";

    std::ifstream f(index_path);
    if (!f.is_open()) {
        std::cout << "[ebuild2pkg] No INDEX found at " << index_path
                  << " — will create it\n";
        return true;
    }

    std::string line;
    while (std::getline(f, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == ' '))
            line.pop_back();
        if (line.empty()) continue;

        IndexEntry e;
        e.rel_path = line;

        fs::path p(line);
        std::string fname = p.filename().string();
        if (fname.size() > 4 && fname.substr(fname.size() - 4) == ".pkg")
            fname = fname.substr(0, fname.size() - 4);

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

        std::string full_path = root + "/" + line;
        if (fs::exists(full_path)) {
            std::ifstream pf(full_path);
            std::string pline;
            while (std::getline(pf, pline)) {
                if (pline.substr(0, 10) == "version = ") {
                    std::string v = pline.substr(10);
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

bool PackageIndex::check(const std::string &pkg_name, const std::string &new_version,
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

void PackageIndex::record(const std::string &pkg_name, const std::string &version,
                          const std::string &rel_path) {
    auto it = by_name_.find(pkg_name);
    if (it != by_name_.end()) {
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

bool PackageIndex::save() const {
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

void PackageIndex::mark_updated(const std::string &rel_path) {
    updated_paths_.push_back(rel_path);
}

const std::vector<std::string> &PackageIndex::new_entries() const {
    return new_entries_;
}

const std::vector<std::string> &PackageIndex::updated_paths() const {
    return updated_paths_;
}
