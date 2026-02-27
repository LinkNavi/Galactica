#include "ebuild.h"
#include <algorithm>
#include <iostream>
#include <set>
#include <sstream>

// Forward declaration from fetcher.cpp
ArchResult arch_lookup(const std::string &pkgname);

// Map one Gentoo atom to a DepResult.
// pkg_name will be empty if the dep should be silently skipped.
// needs_pkg will be true when the dep is AUR or not found in Arch at all —
// the caller must generate a .pkg build file for it.
DepResult map_dep(const std::string &atom) {
    if (atom.empty()) return {};

    // ── Mapping table: exact match ────────────────────────────────────
    auto it = GENTOO_TO_GALACTICA.find(atom);
    if (it != GENTOO_TO_GALACTICA.end()) {
        // Empty value means "skip this dep entirely"
        if (it->second.empty()) return {};
        return { it->second, false, atom };
    }

    // ── Mapping table: slot-stripped match ───────────────────────────
    std::string no_slot = atom;
    size_t colon = no_slot.rfind(':');
    if (colon != std::string::npos) {
        no_slot = no_slot.substr(0, colon);
        it = GENTOO_TO_GALACTICA.find(no_slot);
        if (it != GENTOO_TO_GALACTICA.end()) {
            if (it->second.empty()) return {};
            return { it->second, false, atom };
        }
    }

    // ── Build-only category — skip ────────────────────────────────────
    size_t slash = atom.find('/');
    if (slash != std::string::npos) {
        std::string cat = atom.substr(0, slash);
        for (const auto &bc : BUILD_ONLY_CATEGORIES)
            if (cat == bc) return {};
    }

    // ── Arch / AUR lookup ─────────────────────────────────────────────
    if (slash != std::string::npos) {
        std::string pkgname = atom.substr(slash + 1);
        // Strip slot
        size_t c = pkgname.find(':');
        if (c != std::string::npos) pkgname = pkgname.substr(0, c);
        // Strip version suffix (name-1.2.3 -> name)
        size_t d = pkgname.rfind('-');
        if (d != std::string::npos && !pkgname.empty() && isdigit((unsigned char)pkgname[d + 1]))
            pkgname = pkgname.substr(0, d);

        ArchResult ar = arch_lookup(pkgname);

        if (ar.source == ArchSource::OFFICIAL) {
            // Dreamland can install this as an Arch binary — no .pkg needed
            std::cout << "[ebuild2pkg] Official: '" << atom << "' -> '" << ar.name << "'\n";
            return { ar.name, false, atom };
        }

        if (ar.source == ArchSource::AUR) {
            // AUR package — Dreamland can't binary-install it, generate a .pkg
            std::cout << "[ebuild2pkg] AUR dep '" << ar.name << "' — will generate .pkg\n";
            return { ar.name, true, atom };
        }

        // NOT_FOUND in Arch — try to pull from Gentoo ebuild
        std::cerr << "[ebuild2pkg] Not in Arch: '" << atom << "' — will generate .pkg from Gentoo\n";
        return { pkgname, true, atom };
    }

    // Bare name with no category
    std::cerr << "[ebuild2pkg] Bare dep '" << atom << "' — using as-is, will attempt .pkg\n";
    return { atom, true, atom };
}

// Map a list of atoms.  Returns one DepResult per unique pkg_name,
// preserving all metadata so callers know which deps need pkg files.
std::vector<DepResult> map_deps(const std::vector<std::string> &atoms) {
    std::set<std::string> seen;
    std::vector<DepResult> results;
    for (const auto &atom : atoms) {
        DepResult dr = map_dep(atom);
        if (dr.pkg_name.empty()) continue;
        if (seen.count(dr.pkg_name)) continue;
        seen.insert(dr.pkg_name);
        results.push_back(dr);
    }
    return results;
}

// Detect what type of package this is and generate an appropriate install script
std::string generate_install_script(const Ebuild &eb) {
    std::string name = eb.name;
    std::string desc = eb.description;

    bool is_lib    = (name.size() >= 3 && name.substr(0, 3) == "lib")
                     || name.find("-lib") != std::string::npos;
    bool is_font   = name.find("font") != std::string::npos
                     || desc.find("font") != std::string::npos;
    bool is_theme  = name.find("theme") != std::string::npos
                     || name.find("icon") != std::string::npos;
    bool is_daemon = desc.find("daemon") != std::string::npos
                     || desc.find("server") != std::string::npos
                     || desc.find("service") != std::string::npos;
    bool has_wayland = false, has_gtk = false, has_x11 = false;

    for (const auto &dep : eb.rdepend) {
        if (dep.find("wayland") != std::string::npos) has_wayland = true;
        if (dep.find("gtk")     != std::string::npos) has_gtk     = true;
        if (dep.find("x11")     != std::string::npos
            || dep.find("xcb")  != std::string::npos) has_x11    = true;
    }

    std::stringstream s;

    if (is_font) {
        s << "mkdir -p /usr/share/fonts/" << name << "\n"
          << "cp -r *.ttf *.otf *.woff* /usr/share/fonts/" << name << "/ 2>/dev/null || true\n"
          << "fc-cache -f /usr/share/fonts/" << name << "\n";

    } else if (is_theme) {
        s << "mkdir -p /usr/share/themes/" << name << "\n"
          << "cp -r * /usr/share/themes/" << name << "/\n";

    } else if (is_lib) {
        s << "mkdir -p /usr/lib /usr/include/" << name << " /usr/lib/pkgconfig\n"
          << "find . -name '*.so*' -exec cp -P {} /usr/lib/ \\;\n"
          << "find . -name '*.a'   -exec cp    {} /usr/lib/ \\;\n"
          << "find . -name '*.h'   -exec cp    {} /usr/include/" << name << "/ \\;\n"
          << "find . -name '*.pc'  -exec cp    {} /usr/lib/pkgconfig/ \\; 2>/dev/null || true\n"
          << "ldconfig\n";

    } else if (is_daemon) {
        s << "mkdir -p /usr/bin /usr/lib /etc/" << name << "\n"
          << "[ -f " << name << " ] && { cp " << name << " /usr/bin/" << name
          << "; chmod 755 /usr/bin/" << name << "; }\n"
          << "find . -name '*.so*' -exec cp -P {} /usr/lib/ \\; 2>/dev/null || true\n"
          << "ldconfig\n"
          << "[ -d etc ] && cp -r etc/. /etc/" << name << "/ || true\n"
          << "mkdir -p /etc/airride/services\n"
          << "cat > /etc/airride/services/" << name << ".service << 'SVCEOF'\n"
          << "[Service]\n"
          << "name = \"" << name << "\"\n"
          << "description = \"" << desc << "\"\n"
          << "exec_start = /usr/bin/" << name << "\n"
          << "type = simple\n"
          << "restart = on-failure\n"
          << "autostart = true\n"
          << "parallel = true\n"
          << "SVCEOF\n";

    } else if (has_wayland || has_gtk || has_x11) {
        s << "mkdir -p /usr/bin /usr/share/" << name << " /usr/share/applications\n"
          << "[ -f " << name << " ] && { cp " << name << " /usr/bin/" << name
          << "; chmod 755 /usr/bin/" << name << "; }\n"
          << "find . -name '*.so*' -exec cp -P {} /usr/lib/ \\; 2>/dev/null || true\n"
          << "[ -d share ] && cp -r share/. /usr/share/ || true\n"
          << "[ -d data  ] && cp -r data/.  /usr/share/" << name << "/ || true\n"
          << "if ! find . -name '*.desktop' | grep -q .; then\n"
          << "cat > /usr/share/applications/" << name << ".desktop << 'DEOF'\n"
          << "[Desktop Entry]\n"
          << "Name=" << name << "\n"
          << "Comment=" << desc << "\n"
          << "Exec=" << name << "\n"
          << "Type=Application\n"
          << "DEOF\n"
          << "fi\n"
          << "find . -name '*.desktop' -exec cp {} /usr/share/applications/ \\; 2>/dev/null || true\n";
        if (has_wayland)
            s << "find . -name '*.desktop' -path '*/wayland-sessions/*'"
              << " -exec cp {} /usr/share/wayland-sessions/ \\; 2>/dev/null || true\n";

    } else {
        s << "mkdir -p /usr/bin /usr/lib /usr/share/man /usr/lib/pkgconfig\n"
          << "find . -maxdepth 2 -type f -executable ! -name '*.so*' -exec cp {} /usr/bin/ \\;\n"
          << "find . -name '*.so*' -exec cp -P {} /usr/lib/ \\; 2>/dev/null || true\n"
          << "find . -name '*.pc'  -exec cp    {} /usr/lib/pkgconfig/ \\; 2>/dev/null || true\n"
          << "find . -name 'man*'  -type d -exec cp -r {}/ /usr/share/man/ \\; 2>/dev/null || true\n"
          << "ldconfig 2>/dev/null || true\n";
    }

    return s.str();
}
