#include <algorithm>
#include <climits>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>
#include "dreamland.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <sys/wait.h>
#include <unistd.h>

// ── Arch binary install ───────────────────────────────────────────────────────

bool Dreamland::install_arch(const Package& p) {
    std::cout << "Installing: " << PINK << p.name << RESET << " " << p.version << "\n";
    std::string cached = pkg_cache_dir + "/" + p.filename;
    if (!fs::exists(cached)) {
        status("Downloading...");
        bool got = false;
        for (auto& m : ARCH_MIRRORS) {
            if (dl_file(m + "/" + p.repo + "/os/x86_64/" + p.filename, cached, p.name)) {
                got = true; break;
            }
        }
        if (!got) { err("Download failed for " + p.name); return false; }
    }
    std::vector<std::string> files;
    if (!extract_pkg(cached, "", &files)) { err("Extract failed for " + p.name); return false; }
    std::ofstream mf(manifest_dir + "/" + p.name + ".manifest");
    for (auto& f : files) mf << f << "\n";
    Package ip = p; ip.installed = true;
    installed[p.name] = ip;
    save_installed();
    ok("Installed " + p.name);
    return true;
}

// ── Galactica source install ──────────────────────────────────────────────────

bool Dreamland::install_galactica(const Package& p_in) {
    Package p = p_in;

    // Re-fetch build_script if missing
    if (p.build_script.empty()) {
        dbg("build_script empty for " + p.name + ", re-fetching...");
        bool refetched = false;
        auto try_fetch = [&](const std::string& pkg_path) {
            std::string basename = fs::path(pkg_path).stem().string();
            if (basename != p.name) return false;
            if (!parse_galactica_pkg(pkg_path)) return false;
            auto it = packages.find(p.name);
            if (it == packages.end() || it->second.build_script.empty()) return false;
            p = it->second; return true;
        };
        for (const auto& pp : galactica_pkgs)
            if (try_fetch(pp)) { refetched = true; break; }
        if (!refetched && galactica_pkgs.empty()) {
            fetch_galactica();
            for (const auto& pp : galactica_pkgs)
                if (try_fetch(pp)) { refetched = true; break; }
        }
        if (!refetched) { err("No install script for " + p.name); return false; }
    }

    std::cout << "Installing from source: " << PINK << p.name << RESET
              << " " << p.version << "\n";

    char cwd_buf[PATH_MAX];
    if (!getcwd(cwd_buf, sizeof(cwd_buf))) { err("getcwd failed"); return false; }
    std::string old_cwd = cwd_buf;
    std::string build_path = build_dir + "/" + p.name;

    try {
        fs::create_directories(build_dir);
        fs::create_directories(build_path);
    } catch (const fs::filesystem_error& e) {
        err("mkdir failed: " + std::string(e.what())); return false;
    }

    if (chdir(build_path.c_str()) != 0) {
        err("chdir failed: " + build_path); return false;
    }

    // Download + extract source
    if (!p.url.empty()) {
        status("Downloading source...");
        size_t slash = p.url.find_last_of('/');
        std::string src_filename = slash != std::string::npos
            ? p.url.substr(slash + 1) : p.name + ".tar.gz";
        std::string src_file = build_path + "/" + src_filename;

        if (!dl_file(p.url, src_file, p.name)) {
            err("Failed to download: " + p.url);
            chdir(old_cwd.c_str()); return false;
        }

        if (src_filename.find(".tar") != std::string::npos ||
            src_filename.find(".tgz") != std::string::npos) {
            status("Extracting...");
            std::string tar = fs::exists("/bin/tar") ? "/bin/tar" : "busybox tar";
            std::string extract_cmd;
            if      (src_filename.ends_with(".tar.gz") || src_filename.ends_with(".tgz"))
                extract_cmd = tar + " -xzf " + src_file;
            else if (src_filename.ends_with(".tar.bz2"))
                extract_cmd = tar + " -xjf " + src_file;
            else if (src_filename.ends_with(".tar.xz"))
                extract_cmd = tar + " -xJf " + src_file;
            else
                extract_cmd = tar + " -xf " + src_file;

            if (exec(extract_cmd + " 2>/dev/null") != 0) {
                if (exec(tar + " -xf " + src_file + " 2>/dev/null") != 0) {
                    err("Extraction failed"); chdir(old_cwd.c_str()); return false;
                }
            }

            // cd into single subdir for source packages only
            if (p.type != "kernel" && p.type != "binary") {
                std::vector<fs::path> subdirs;
                for (auto& e : fs::directory_iterator(build_path))
                    if (e.is_directory()) subdirs.push_back(e.path());
                if (subdirs.size() == 1) chdir(subdirs[0].c_str());
            }
        }
    }

    // Run install script
    if (!p.build_script.empty()) {
        status("Running install script...");
        std::ofstream script("build.sh");
        if (!script) { err("Cannot write build.sh"); chdir(old_cwd.c_str()); return false; }
        script << "#!/bin/sh\nset -e\n\n" << p.build_script << "\n";
        script.close();
        chmod("build.sh", 0755);
        int result = system("sh build.sh 2>&1");
        if (result != 0) {
            err("Install script failed (exit " + std::to_string(WEXITSTATUS(result)) + ")");
            chdir(old_cwd.c_str()); return false;
        }
    }

    chdir(old_cwd.c_str());
    Package ip = p; ip.installed = true;
    installed[p.name] = ip;
    save_installed();
    ok("Installed " + p.name);
    return true;
}

// ── Kernel install ────────────────────────────────────────────────────────────

bool Dreamland::install_kernel(const Package& p) {
    std::cout << "Installing kernel: " << PINK << p.name << RESET << " " << p.version << "\n";
    if (geteuid() != 0) { err("Kernel install requires root"); return false; }
    if (!install_galactica(p)) return false;
    status("Running depmod...");
    exec("depmod " + p.version + " 2>/dev/null || depmod -a 2>/dev/null");
    if (access("/usr/sbin/ginitrd", X_OK) == 0) {
        status("Generating initramfs...");
        std::string img = "/boot/initramfs-" + p.version + ".img";
        if (exec("ginitrd -o " + img + " 2>&1") == 0) ok("Initramfs: " + img);
        else warn("ginitrd failed — generate initramfs manually");
    } else {
        warn("ginitrd not found — skipping initramfs");
    }
    status("Updating GRUB...");
    if (exec("grub-mkconfig -o /boot/grub/grub.cfg 2>&1") == 0) ok("GRUB updated");
    else warn("grub-mkconfig failed — update manually");
    ok("Kernel " + p.version + " installed — reboot to use");
    return true;
}

// ── Uninstall ─────────────────────────────────────────────────────────────────

bool Dreamland::uninstall_pkg(const std::string& name) {
    ensure_installed();
    auto it = installed.find(name);
    if (it == installed.end()) { err("Not installed: " + name); return false; }
    Package& p = it->second;
    status("Uninstalling: " + name);

    if (p.type == "kernel") {
        if (geteuid() != 0) { err("Kernel removal requires root"); return false; }
        warn("Removing kernel " + p.version);
        exec("rm -f /boot/vmlinuz-" + p.version + " /boot/initramfs-" + p.version + ".img 2>/dev/null");
        exec("rm -rf /lib/modules/" + p.version + " 2>/dev/null");
        exec("grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null");
        installed.erase(name); save_installed();
        ok("Kernel removed"); return true;
    }

    if (p.source == PackageSource::MODULE) {
        auto mit = modules.find(name);
        if (mit != modules.end()) {
            if (mit->second.cleanup) mit->second.cleanup();
            dlclose(mit->second.handle);
            modules.erase(mit);
        }
        std::string mod_path = modules_dir + "/" + name + ".so";
        if (fs::exists(mod_path)) fs::remove(mod_path);
        ok("Module removed");
    } else {
        std::string mf = manifest_dir + "/" + name + ".manifest";
        if (fs::exists(mf)) {
            std::ifstream f(mf); std::string line;
            std::vector<std::string> files;
            while (std::getline(f, line)) if (!line.empty()) files.push_back(line);
            std::sort(files.rbegin(), files.rend());
            int removed = 0;
            for (auto& file : files) {
                try { if (fs::exists(file)) { fs::remove(file); removed++; } } catch(...) {}
            }
            fs::remove(mf);
            ok("Removed " + std::to_string(removed) + " files");
        } else {
            warn("No manifest found — removing from db only");
        }
    }

    // Clean build dir
    std::string bdir = build_dir + "/" + name;
    if (fs::exists(bdir)) {
        std::error_code ec; fs::remove_all(bdir, ec);
        if (!ec) dbg("Build dir cleaned: " + bdir);
    }

    installed.erase(name); save_installed();
    ok("Uninstalled: " + name);
    return true;
}
