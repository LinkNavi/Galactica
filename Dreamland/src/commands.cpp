#include "dreamland.h"
#include <algorithm>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <cstring>
// ── sync ──────────────────────────────────────────────────────────────────────

void Dreamland::sync() {
    banner();
    // Wipe old db cache so we get fresh data
    std::error_code ec;
    if (fs::exists(db_cache_dir, ec)) {
        std::cout << "Removing old cache...\n";
        if (fs::remove_all(db_cache_dir, ec)) ok("Old cache removed");
        else warn("Could not remove old cache: " + ec.message());
    }
    fetch_galactica();
    load_galactica_packages();
    sync_arch();
    save_pkg_db();
    db_loaded   = true;
    ensure_installed();
    ok("Sync complete");
    std::cout << "  " << packages.size()  << " packages available\n";
    std::cout << "  " << modules.size()   << " modules loaded\n";
}

// ── install (single) ──────────────────────────────────────────────────────────

bool Dreamland::install(const std::string& name, bool reinstall) {
    ensure_installed();
    ensure_db();

    if (installed.count(name) && !reinstall) {
        warn(name + " is already installed (use --reinstall to force)");
        return false;
    }

    auto it = packages.find(name);
    if (it == packages.end()) { err("Package not found: " + name); return false; }
    const Package& pkg = it->second;

    if (pkg.source == PackageSource::GALACTICA) {
        for (const auto& dep : pkg.dependencies) {
            if (!installed.count(dep)) {
                auto dit = packages.find(dep);
                if (dit != packages.end()) install(dep);
                else warn("Dep not found: " + dep);
            }
        }
        if (pkg.type == "kernel") return install_kernel(pkg);
        return install_galactica(pkg);

    } else if (pkg.source == PackageSource::ARCH_BINARY) {
        status("Resolving dependencies for " + name + "...");
        std::set<std::string> resolved, visited;
        std::vector<std::string> order = resolve_dependencies(name, resolved, visited);
        if (order.empty()) order.push_back(name);

        // Filter already-installed unless reinstall
        std::vector<std::string> to_install;
        for (auto& n : order)
            if (!installed.count(n) || reinstall) to_install.push_back(n);

        if (to_install.empty()) { ok(name + " and all deps already installed"); return true; }

        std::cout << "\n" << CYAN << "Packages to install (" << to_install.size() << "):" << RESET << "\n";
        size_t total = 0;
        for (auto& n : to_install) {
            auto pit = packages.find(n);
            if (pit == packages.end()) continue;
            std::cout << "  " << n << " " << YELLOW << pit->second.version << RESET << "\n";
            total += pit->second.size;
        }
        std::cout << "\n" << CYAN << "Download size: " << RESET;
        if      (total >= 1024*1024) std::cout << std::fixed << std::setprecision(1) << total/1048576.0 << " MB\n";
        else if (total >= 1024)      std::cout << total/1024.0 << " KB\n";
        else                         std::cout << total << " B\n";
        return true; // caller (install_multi) handles confirmation
    }
    return false;
}

// ── install_multi (multi-package with single confirmation) ────────────────────

bool Dreamland::install_multi(const std::vector<std::string>& names,
                               bool reinstall, bool yes) {
    ensure_installed();
    ensure_db();

    // Separate Galactica (install immediately, no confirmation needed) vs Arch
    std::vector<std::string> arch_pkgs, galactica_pkgs_to_install;
    std::vector<std::string> not_found;

    for (auto& name : names) {
        if (installed.count(name) && !reinstall) {
            warn(name + " already installed — skipping (--reinstall to force)");
            continue;
        }
        auto it = packages.find(name);
        if (it == packages.end()) { not_found.push_back(name); continue; }
        if (it->second.source == PackageSource::GALACTICA ||
            it->second.type   == "kernel")
            galactica_pkgs_to_install.push_back(name);
        else
            arch_pkgs.push_back(name);
    }

    for (auto& n : not_found) err("Package not found: " + n);

    // ── Galactica packages ────────────────────────────────────────────────────
    bool all_ok = true;
    for (auto& name : galactica_pkgs_to_install) {
        auto it = packages.find(name);
        if (it == packages.end()) continue;
        // Install deps first
        for (auto& dep : it->second.dependencies)
            if (!installed.count(dep)) install(dep);
        bool ok = (it->second.type == "kernel")
            ? install_kernel(it->second)
            : install_galactica(it->second);
        if (!ok) all_ok = false;
    }

    // ── Arch packages — collect full dep graph across all requested ───────────
    if (!arch_pkgs.empty()) {
        std::set<std::string> resolved, visited;
        std::vector<std::string> full_order;

        for (auto& name : arch_pkgs) {
            auto sub = resolve_dependencies(name, resolved, visited);
            full_order.insert(full_order.end(), sub.begin(), sub.end());
        }
        // Make sure explicitly requested pkgs are in the list
        for (auto& name : arch_pkgs)
            if (!resolved.count(name)) { full_order.push_back(name); resolved.insert(name); }

        // Filter already installed
        std::vector<std::string> to_install;
        for (auto& n : full_order)
            if (!installed.count(n) || reinstall) to_install.push_back(n);

        if (to_install.empty()) {
            ok("All packages already installed");
        } else {
            std::cout << "\n" << CYAN << "Packages to install (" << to_install.size() << "):" << RESET << "\n";
            size_t total = 0;
            for (auto& n : to_install) {
                auto pit = packages.find(n);
                if (pit == packages.end()) continue;
                std::cout << "  " << PINK << n << RESET
                          << " " << YELLOW << pit->second.version << RESET << "\n";
                total += pit->second.size;
            }
            std::cout << "\n" << CYAN << "Total download size: " << RESET;
            if      (total >= 1024*1024) std::cout << std::fixed << std::setprecision(1) << total/1048576.0 << " MB\n";
            else if (total >= 1024)      std::cout << total/1024.0 << " KB\n";
            else                         std::cout << total << " B\n";

            if (!yes) {
                std::cout << "\nProceed? [Y/n]: ";
                std::string resp; std::getline(std::cin, resp);
                if (!resp.empty() && resp[0] != 'y' && resp[0] != 'Y') {
                    std::cout << "Cancelled.\n"; return false;
                }
            }

            for (auto& n : to_install) {
                auto pit = packages.find(n);
                if (pit == packages.end()) continue;
                if (!install_arch(pit->second)) { err("Failed: " + n); all_ok = false; }
            }
            if (all_ok) ok("Installed " + std::to_string(to_install.size()) + " package(s)");
        }
    }

    return all_ok && not_found.empty();
}

// ── uninstall ─────────────────────────────────────────────────────────────────

bool Dreamland::uninstall(const std::string& name) { return uninstall_pkg(name); }

// ── upgrade ───────────────────────────────────────────────────────────────────

void Dreamland::upgrade() {
    banner();
    ensure_installed();
    ensure_db();

    std::vector<std::pair<Package, Package>> upgradeable;
    for (auto& [name, inst] : installed) {
        auto it = packages.find(name);
        if (it == packages.end()) continue;
        if (it->second.version != inst.version)
            upgradeable.push_back({inst, it->second});
    }

    if (upgradeable.empty()) { ok("System is up to date"); return; }

    std::cout << "\n" << CYAN << "Packages to upgrade (" << upgradeable.size() << "):" << RESET << "\n";
    for (auto& [old_p, new_p] : upgradeable) {
        std::cout << "  " << PINK << old_p.name << RESET
                  << " " << YELLOW << old_p.version << RESET
                  << " -> " << GREEN << new_p.version << RESET;
        if (new_p.type == "kernel") std::cout << " " << CYAN << "[kernel — reboot required]" << RESET;
        std::cout << "\n";
    }

    std::cout << "\nProceed? [Y/n]: ";
    std::string resp; std::getline(std::cin, resp);
    if (!resp.empty() && resp[0] != 'y' && resp[0] != 'Y') { std::cout << "Cancelled.\n"; return; }

    for (auto& [old_p, new_p] : upgradeable) {
        status("Upgrading " + old_p.name + "...");
        // Remove old manifest files
        std::string mf = manifest_dir + "/" + old_p.name + ".manifest";
        if (fs::exists(mf)) {
            std::ifstream f(mf); std::string line;
            while (std::getline(f, line)) if (!line.empty()) fs::remove(line);
        }
        installed.erase(old_p.name);

        bool ok_flag = false;
        if (new_p.source == PackageSource::GALACTICA)
            ok_flag = (new_p.type == "kernel") ? install_kernel(new_p) : install_galactica(new_p);
        else
            ok_flag = install_arch(new_p);

        if (!ok_flag) err("Failed to upgrade " + old_p.name);
    }
    ok("Upgrade complete");
}

// ── search ────────────────────────────────────────────────────────────────────

void Dreamland::search(const std::string& q) {
    ensure_db();
    ensure_installed();

    int count = 0;
    for (auto& [n, p] : packages) {
        if (n.find(q) == std::string::npos && p.description.find(q) == std::string::npos) continue;
        std::string src = p.source == PackageSource::GALACTICA ? CYAN "[galactica]" RESET
                                                               : YELLOW "[arch]" RESET;
        std::cout << PINK << n << RESET << " " << p.version << " " << src;
        if (p.type == "kernel")       std::cout << " " << BLUE << "[kernel]" << RESET;
        if (installed.count(n))       std::cout << " " << GREEN << "[installed]" << RESET;
        if (!p.description.empty())   std::cout << "\n  " << p.description;
        std::cout << "\n";
        count++;
    }
    if (count == 0) std::cout << "No packages found matching '" << q << "'\n";
    else std::cout << "\n" << count << " result(s)\n";
}

// ── list ──────────────────────────────────────────────────────────────────────

void Dreamland::list() {
    banner();
    ensure_installed();
    if (installed.empty()) { warn("Nothing installed"); return; }

    // Check for available upgrades
    if (db_loaded) {
        int upgrades = 0;
        for (auto& [n, p] : installed) {
            auto it = packages.find(n);
            if (it != packages.end() && it->second.version != p.version) upgrades++;
        }
        if (upgrades > 0)
            std::cout << YELLOW << "  " << upgrades << " upgrade(s) available — run 'dl upgrade'\n" << RESET;
    }
    std::cout << "\n";

    for (auto& [n, p] : installed) {
        std::string src = p.source == PackageSource::MODULE    ? PINK "[module]" RESET
                        : p.source == PackageSource::GALACTICA ? CYAN "[source]" RESET
                                                               : YELLOW "[binary]" RESET;
        std::string kt  = p.type == "kernel" ? BLUE " [kernel]" RESET : "";
        std::string upg;
        if (db_loaded) {
            auto it = packages.find(n);
            if (it != packages.end() && it->second.version != p.version)
                upg = GREEN " [" + it->second.version + " available]" RESET;
        }
        std::cout << "  " << n << " " << p.version << " " << src << kt << upg << "\n";
    }
    std::cout << "\n  " << installed.size() << " package(s) installed\n";
}

// ── info ──────────────────────────────────────────────────────────────────────

void Dreamland::info(const std::string& name) {
    ensure_db();
    ensure_installed();

    auto it = packages.find(name);
    if (it == packages.end()) { err("Package not found: " + name); return; }
    const Package& p = it->second;

    std::cout << "\n";
    std::cout << PINK << "Name:        " << RESET << p.name << "\n";
    std::cout << PINK << "Version:     " << RESET << p.version << "\n";
    std::cout << PINK << "Description: " << RESET << p.description << "\n";
    std::cout << PINK << "Category:    " << RESET << p.category << "\n";

    std::string src_str = p.source == PackageSource::GALACTICA ? "Galactica (source)"
                        : p.source == PackageSource::ARCH_BINARY ? "Arch Linux (binary)"
                                                                  : "Module";
    std::cout << PINK << "Source:      " << RESET << src_str << "\n";

    if (p.source == PackageSource::ARCH_BINARY && p.size > 0) {
        std::cout << PINK << "Download:    " << RESET;
        if (p.size >= 1024*1024) std::cout << std::fixed << std::setprecision(1) << p.size/1048576.0 << " MB\n";
        else                     std::cout << p.size/1024.0 << " KB\n";
    }
    if (!p.url.empty())
        std::cout << PINK << "URL:         " << RESET << p.url << "\n";
    if (!p.type.empty())
        std::cout << PINK << "Type:        " << RESET << p.type << "\n";
    if (!p.dependencies.empty()) {
        std::cout << PINK << "Depends:     " << RESET;
        for (size_t i = 0; i < p.dependencies.size(); i++) {
            if (i) std::cout << "  ";
            std::cout << p.dependencies[i];
            if (installed.count(p.dependencies[i])) std::cout << GREEN << " ✓" << RESET;
        }
        std::cout << "\n";
    }
    bool inst = installed.count(name) > 0;
    std::cout << PINK << "Installed:   " << RESET
              << (inst ? GREEN "yes" RESET : RED "no" RESET) << "\n";
    if (inst) {
        // Check for upgrade
        auto iit = installed.find(name);
        if (iit->second.version != p.version)
            std::cout << YELLOW << "  (installed: " << iit->second.version
                      << ", available: " << p.version << ")" << RESET << "\n";
    }
    std::cout << "\n";
}

// ── files ─────────────────────────────────────────────────────────────────────

void Dreamland::files(const std::string& name) {
    ensure_installed();
    if (!installed.count(name)) { err("Not installed: " + name); return; }

    std::string mf = manifest_dir + "/" + name + ".manifest";
    if (!fs::exists(mf)) {
        warn("No file manifest for " + name + " (Galactica source packages may not have one)");
        return;
    }

    std::ifstream f(mf); std::string line; int count = 0;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        bool exists = fs::exists(line);
        std::cout << (exists ? "  " : RED "  [missing] " RESET) << line << "\n";
        count++;
    }
    std::cout << "\n  " << count << " file(s)\n";
}

// ── clean ─────────────────────────────────────────────────────────────────────

void Dreamland::clean() {
    banner();
    size_t freed = 0;

    auto remove_dir = [&](const std::string& dir, const std::string& label) {
        if (!fs::exists(dir)) return;
        std::error_code ec;
        size_t sz = 0;
        for (auto& e : fs::recursive_directory_iterator(dir, ec))
            if (e.is_regular_file(ec)) sz += e.file_size(ec);
        fs::remove_all(dir, ec);
        fs::create_directories(dir);
        freed += sz;
        ok("Cleaned " + label + " (" + std::to_string(sz/1024) + " KB)");
    };

    remove_dir(pkg_cache_dir, "package cache");
    remove_dir(build_dir,     "build directory");
    remove_dir(db_cache_dir,  "database cache");

    // Remove stale pkg db so next sync fetches fresh
    if (fs::exists(pkg_db)) { fs::remove(pkg_db); ok("Removed package db"); }

    db_loaded = false; // force reload on next operation

    std::cout << "\n  Total freed: ";
    if (freed >= 1024*1024) std::cout << std::fixed << std::setprecision(1) << freed/1048576.0 << " MB\n";
    else                    std::cout << freed/1024 << " KB\n";
    std::cout << "  Run 'dl sync' to rebuild the package database\n";
}

// ── modules ───────────────────────────────────────────────────────────────────

void Dreamland::list_mods() {
    banner();
    std::cout << "Modules (" << modules.size() << "):\n\n";
    if (modules.empty()) { std::cout << "  None. Install: dl install module-<name>\n"; return; }
    for (auto& [n, m] : modules) {
        std::cout << PINK << "  " << m.info->name << RESET << " v" << m.info->version << "\n";
        std::cout << "    " << m.info->description << "\n";
        for (auto& c : m.commands)
            std::cout << "    " << CYAN << c.name << RESET << " — " << c.description << "\n";
        std::cout << "\n";
    }
}

// ── usage ─────────────────────────────────────────────────────────────────────

void Dreamland::usage(const std::string& prog) {
    banner();
    std::cout << "Usage: " << prog << " <command> [options] [args]\n\n";
    std::cout << "Commands:\n";
    std::cout << "  sync                  Sync package databases\n";
    std::cout << "  install [-y] [--reinstall] <pkg...>\n";
    std::cout << "                        Install one or more packages\n";
    std::cout << "  uninstall <pkg>       Uninstall a package\n";
    std::cout << "  upgrade               Upgrade all installed packages\n";
    std::cout << "  search <query>        Search packages\n";
    std::cout << "  info <pkg>            Show package details\n";
    std::cout << "  files <pkg>           List files owned by a package\n";
    std::cout << "  list                  List installed packages\n";
    std::cout << "  clean                 Clear download and build caches\n";
    std::cout << "  modules               List loaded modules\n";
    if (!modules.empty()) {
        std::cout << "\nModule commands:\n";
        for (auto& [n, m] : modules)
            for (auto& c : m.commands)
                std::cout << "  " << c.name
                          << std::string(std::max(1, 16 - (int)strlen(c.name)), ' ')
                          << c.description << " [" << m.info->name << "]\n";
    }
    std::cout << "\nExamples:\n";
    std::cout << "  dl sync\n";
    std::cout << "  dl install curl hyprland firefox\n";
    std::cout << "  dl install -y neovim\n";
    std::cout << "  dl info firefox\n";
    std::cout << "  dl files curl\n";
    std::cout << "  dl clean\n";
}
