#pragma once
#include <string>
#include <vector>
#include <map>

struct IndexEntry {
    std::string rel_path;
    std::string pkg_name;
    std::string version;
};

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
    std::vector<IndexEntry>             entries_;
    std::map<std::string, size_t>       by_name_;
    std::vector<std::string>            new_entries_;
    std::vector<std::string>            updated_paths_;
};
