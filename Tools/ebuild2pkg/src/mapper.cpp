#include "ebuild.h"
#include <algorithm>
#include <iostream>
#include <set>
#include <sstream>

// Forward declaration from fetcher.cpp
std::string arch_lookup(const std::string &pkgname);

// Map a single Gentoo atom to a Galactica package name.
// Returns "" if it should be skipped (build tool, unknown, etc.)
std::string map_dep(const std::string &atom) {
    // Skip empty
    if (atom.empty()) return "";

    // Try exact match first
    auto it = GENTOO_TO_GALACTICA.find(atom);
    if (it != GENTOO_TO_GALACTICA.end())
        return it->second;

    // Try without slot (strip ":N" suffix)
    std::string no_slot = atom;
    size_t colon = no_slot.rfind(':');
    if (colon != std::string::npos) {
        no_slot = no_slot.substr(0, colon);
        it = GENTOO_TO_GALACTICA.find(no_slot);
        if (it != GENTOO_TO_GALACTICA.end())
            return it->second;
    }

    // Check if it's a build-only category — skip
    size_t slash = atom.find('/');
    if (slash != std::string::npos) {
        std::string cat = atom.substr(0, slash);
        for (const auto &bc : BUILD_ONLY_CATEGORIES)
            if (cat == bc) return "";
    }

    // Fall back: try Arch package repos for the bare name
    if (slash != std::string::npos) {
        std::string pkgname = atom.substr(slash + 1);
        size_t c = pkgname.find(':');
        if (c != std::string::npos) pkgname = pkgname.substr(0, c);

        std::string arch_name = arch_lookup(pkgname);
        if (!arch_name.empty()) {
            std::cout << "[ebuild2pkg] Arch match: '" << atom << "' -> '" << arch_name << "'\n";
            return arch_name;
        }

        std::cerr << "[ebuild2pkg] Unknown dep '" << atom << "' — using '" << pkgname << "' as-is\n";
        return pkgname;
    }

    return atom;
}

std::vector<std::string> map_deps(const std::vector<std::string> &atoms) {
    std::set<std::string> seen;
    std::vector<std::string> result;
    for (const auto &atom : atoms) {
        std::string mapped = map_dep(atom);
        if (!mapped.empty() && !seen.count(mapped)) {
            seen.insert(mapped);
            result.push_back(mapped);
        }
    }
    return result;
}

// Detect what's likely in a tarball based on common ebuild patterns
// and generate an appropriate install script
std::string generate_install_script(const Ebuild &eb) {
    std::string name = eb.name;
    std::string desc = eb.description;
    std::string lower_name = name;
    std::transform(lower_name.begin(), lower_name.end(), lower_name.begin(), ::tolower);

    // Detect type based on name, description, deps
    bool is_lib    = (name.substr(0, 3) == "lib" || name.find("-lib") != std::string::npos);
    bool is_font   = (name.find("font") != std::string::npos || desc.find("font") != std::string::npos);
    bool is_theme  = (name.find("theme") != std::string::npos || name.find("icon") != std::string::npos);
    bool is_daemon = (desc.find("daemon") != std::string::npos || desc.find("server") != std::string::npos || desc.find("service") != std::string::npos);
    bool has_wayland = false;
    bool has_gtk    = false;
    bool has_x11    = false;

    for (const auto &dep : eb.rdepend) {
        if (dep.find("wayland") != std::string::npos) has_wayland = true;
        if (dep.find("gtk") != std::string::npos)     has_gtk = true;
        if (dep.find("x11") != std::string::npos || dep.find("xcb") != std::string::npos) has_x11 = true;
    }

    std::stringstream s;

    if (is_font) {
        s << "mkdir -p /usr/share/fonts/" << name << "\n";
        s << "cp -r *.ttf *.otf *.woff* /usr/share/fonts/" << name << "/ 2>/dev/null || true\n";
        s << "fc-cache -f /usr/share/fonts/" << name << "\n";

    } else if (is_theme) {
        s << "mkdir -p /usr/share/themes/" << name << "\n";
        s << "cp -r * /usr/share/themes/" << name << "/\n";

    } else if (is_lib) {
        s << "mkdir -p /usr/lib /usr/include/" << name << "\n";
        s << "find . -name '*.so*' -exec cp -P {} /usr/lib/ \\;\n";
        s << "find . -name '*.a'   -exec cp    {} /usr/lib/ \\;\n";
        s << "find . -name '*.h'   -exec cp    {} /usr/include/" << name << "/ \\;\n";
        s << "find . -name '*.pc'  -exec cp    {} /usr/lib/pkgconfig/ \\; 2>/dev/null || true\n";
        s << "ldconfig\n";

    } else if (is_daemon) {
        s << "mkdir -p /usr/bin /usr/lib /etc/" << name << "\n";
        // Binary
        s << "[ -f " << name << " ] && { cp " << name << " /usr/bin/" << name << "; chmod 755 /usr/bin/" << name << "; }\n";
        // Libs
        s << "find . -name '*.so*' -exec cp -P {} /usr/lib/ \\; 2>/dev/null || true\n";
        s << "ldconfig\n";
        // Config
        s << "[ -d etc ] && cp -r etc/. /etc/" << name << "/ || true\n";
        // AirRide service file
        s << "mkdir -p /etc/airride/services\n";
        s << "cat > /etc/airride/services/" << name << ".service << 'SVCEOF'\n";
        s << "[Service]\n";
        s << "name = \"" << name << "\"\n";
        s << "description = \"" << desc << "\"\n";
        s << "exec_start = /usr/bin/" << name << "\n";
        s << "type = simple\n";
        s << "restart = on-failure\n";
        s << "autostart = true\n";
        s << "parallel = true\n";
        s << "SVCEOF\n";

    } else if (has_wayland || has_gtk || has_x11) {
        // GUI app
        s << "mkdir -p /usr/bin /usr/share/" << name << " /usr/share/applications\n";
        s << "[ -f " << name << " ] && { cp " << name << " /usr/bin/" << name << "; chmod 755 /usr/bin/" << name << "; }\n";
        s << "find . -name '*.so*' -exec cp -P {} /usr/lib/ \\; 2>/dev/null || true\n";
        s << "[ -d share ] && cp -r share/. /usr/share/ || true\n";
        s << "[ -d data  ] && cp -r data/.  /usr/share/" << name << "/ || true\n";
        // Desktop file if it doesn't provide one
        s << "if ! find . -name '*.desktop' | grep -q .; then\n";
        s << "cat > /usr/share/applications/" << name << ".desktop << 'DEOF'\n";
        s << "[Desktop Entry]\n";
        s << "Name=" << name << "\n";
        s << "Comment=" << desc << "\n";
        s << "Exec=" << name << "\n";
        s << "Type=Application\n";
        s << "DEOF\n";
        s << "fi\n";
        s << "find . -name '*.desktop' -exec cp {} /usr/share/applications/ \\; 2>/dev/null || true\n";
        if (has_wayland) {
            s << "find . -name '*.desktop' -path '*/wayland-sessions/*' -exec cp {} /usr/share/wayland-sessions/ \\; 2>/dev/null || true\n";
        }

    } else {
        // Generic CLI tool
        s << "mkdir -p /usr/bin /usr/lib /usr/share/man\n";
        s << "find . -maxdepth 2 -type f -executable ! -name '*.so*' -exec cp {} /usr/bin/ \\;\n";
        s << "find . -name '*.so*' -exec cp -P {} /usr/lib/ \\; 2>/dev/null || true\n";
        s << "find . -name '*.pc'  -exec cp    {} /usr/lib/pkgconfig/ \\; 2>/dev/null || true\n";
        s << "find . -name 'man*'  -type d -exec cp -r {}/ /usr/share/man/ \\; 2>/dev/null || true\n";
        s << "ldconfig 2>/dev/null || true\n";
    }

    return s.str();
}