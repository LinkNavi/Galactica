#include "ebuild.h"
#include <fstream>
#include <iostream>
#include <sstream>

// Forward declarations
std::string map_dep(const std::string &atom);
std::vector<std::string> map_deps(const std::vector<std::string> &atoms);
std::string generate_install_script(const Ebuild &eb);

// Merge rdepend + depend, dedup, map to Galactica names
static std::vector<std::string> build_dep_list(const Ebuild &eb) {
    std::vector<std::string> all = eb.rdepend;
    for (const auto &d : eb.depend) {
        bool found = false;
        for (const auto &r : eb.rdepend)
            if (r == d) { found = true; break; }
        if (!found) all.push_back(d);
    }
    return map_deps(all);
}

PkgFile ebuild_to_pkg(const Ebuild &eb, const std::string &category) {
    PkgFile pkg;
    pkg.name        = eb.name;
    pkg.version     = eb.version;
    pkg.description = eb.description;
    pkg.url         = eb.src_uri;
    pkg.category    = category.empty() ? "misc" : category;
    pkg.depends     = build_dep_list(eb);
    pkg.install_script = generate_install_script(eb);
    return pkg;
}

bool write_pkg_file(const PkgFile &pkg, const std::string &outpath) {
    std::ofstream f(outpath);
    if (!f.is_open()) {
        std::cerr << "[ebuild2pkg] Cannot write: " << outpath << std::endl;
        return false;
    }

    f << "[Package]\n";
    f << "name = \"" << pkg.name << "\"\n";
    f << "version = \"" << pkg.version << "\"\n";
    f << "description = \"" << pkg.description << "\"\n";
    f << "url = \"" << pkg.url << "\"\n";
    f << "category = \"" << pkg.category << "\"\n";

    f << "\n[Dependencies]\n";
    if (!pkg.depends.empty()) {
        f << "depends = \"";
        for (size_t i = 0; i < pkg.depends.size(); i++) {
            if (i > 0) f << " ";
            f << pkg.depends[i];
        }
        f << "\"\n";
    }

    f << "\n[Script]\n";
    f << pkg.install_script;

    std::cout << "[ebuild2pkg] Written: " << outpath << std::endl;
    return true;
}