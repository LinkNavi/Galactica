#include "pkgtest.h"
#include <fstream>
#include <iostream>
#include <sstream>

PkgInfo parse_pkg_file(const std::string &filepath) {
    PkgInfo pkg;
    pkg.filepath = filepath;

    std::ifstream f(filepath);
    if (!f.is_open()) return pkg;

    std::string line, section;
    bool in_script = false;

    while (std::getline(f, line)) {
        // Section headers
        if (!in_script && !line.empty() && line[0] == '[' && line.back() == ']') {
            section = line.substr(1, line.size() - 2);
            in_script = (section == "Script");
            continue;
        }

        if (in_script) {
            pkg.install_script += line + "\n";
            continue;
        }

        if (section == "Package" || section == "Dependencies") {
            size_t eq = line.find('=');
            if (eq == std::string::npos) continue;
            std::string key = line.substr(0, eq);
            std::string val = line.substr(eq + 1);

            // Trim
            key.erase(key.find_last_not_of(" \t") + 1);
            val.erase(0, val.find_first_not_of(" \t"));
            // Strip quotes
            if (val.size() >= 2 && val.front() == '"' && val.back() == '"')
                val = val.substr(1, val.size() - 2);

            if      (key == "name")        pkg.name        = val;
            else if (key == "version")     pkg.version     = val;
            else if (key == "description") pkg.description = val;
            else if (key == "url")         pkg.url         = val;
            else if (key == "category")    pkg.category    = val;
            else if (key == "depends") {
                std::istringstream ss(val);
                std::string dep;
                while (ss >> dep) pkg.depends.push_back(dep);
            }
        }
    }
    return pkg;
}