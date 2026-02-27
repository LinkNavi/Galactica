#include "ebuild.h"
#include <fstream>
#include <iostream>
#include <sstream>

// Forward declarations from mapper.cpp
std::vector<DepResult> map_deps(const std::vector<std::string> &atoms);
std::string generate_install_script(const Ebuild &eb);

// Returned by ebuild_to_pkg so convert_file can see which deps need pkg files.
struct ConvertResult {
    PkgFile              pkg;
    std::vector<DepResult> pending; // deps with needs_pkg == true
};

// Merge rdepend + depend without duplicates
static std::vector<std::string> merged_atoms(const Ebuild &eb) {
    std::vector<std::string> all = eb.rdepend;
    for (const auto &d : eb.depend) {
        bool dup = false;
        for (const auto &r : eb.rdepend) if (r == d) { dup = true; break; }
        if (!dup) all.push_back(d);
    }
    return all;
}

ConvertResult ebuild_to_pkg(const Ebuild &eb, const std::string &category) {
    auto dep_results = map_deps(merged_atoms(eb));

    PkgFile pkg;
    pkg.name           = eb.name;
    pkg.version        = eb.version;
    pkg.description    = eb.description;
    pkg.url            = eb.src_uri;
    pkg.category       = category.empty() ? "misc" : category;
    pkg.install_script = generate_install_script(eb);

    ConvertResult result;
    result.pkg = pkg;

    for (const auto &dr : dep_results) {
        result.pkg.depends.push_back(dr.pkg_name);
        if (dr.needs_pkg)
            result.pending.push_back(dr);
    }

    return result;
}

bool write_pkg_file(const PkgFile &pkg, const std::string &outpath) {
    std::ofstream f(outpath);
    if (!f.is_open()) {
        std::cerr << "[ebuild2pkg] Cannot write: " << outpath << std::endl;
        return false;
    }

    f << "[Package]\n"
      << "name = \""        << pkg.name        << "\"\n"
      << "version = \""     << pkg.version     << "\"\n"
      << "description = \"" << pkg.description << "\"\n"
      << "url = \""         << pkg.url         << "\"\n"
      << "category = \""    << pkg.category    << "\"\n";

    f << "\n[Dependencies]\n";
    if (!pkg.depends.empty()) {
        f << "depends = \"";
        for (size_t i = 0; i < pkg.depends.size(); i++) {
            if (i > 0) f << " ";
            f << pkg.depends[i];
        }
        f << "\"\n";
    }

    f << "\n[Script]\n"
      << pkg.install_script;

    std::cout << "[ebuild2pkg] Written: " << outpath << std::endl;
    return true;
}
