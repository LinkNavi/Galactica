#pragma GCC diagnostic ignored "-Wunused-result"
#include "pkgtest.h"
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>
#include <sstream>
#include <cstdlib>
#include <unistd.h>

namespace fs = std::filesystem;

// ── Format validation ─────────────────────────────────────────────────────────
TestResult test_format(const PkgInfo &pkg) {
    std::vector<std::string> missing;
    if (pkg.name.empty())        missing.push_back("name");
    if (pkg.version.empty())     missing.push_back("version");
    if (pkg.description.empty()) missing.push_back("description");
    if (pkg.url.empty())         missing.push_back("url");
    if (pkg.install_script.empty()) missing.push_back("install script");

    if (!missing.empty()) {
        std::string msg = "Missing fields: ";
        for (size_t i = 0; i < missing.size(); i++) {
            if (i) msg += ", ";
            msg += missing[i];
        }
        return {"Format validation", TestStatus::FAIL, msg};
    }

    // URL must be http/https
    if (pkg.url.substr(0, 4) != "http") {
        return {"Format validation", TestStatus::FAIL, "URL does not start with http(s): " + pkg.url};
    }

    // Version should not be empty or contain spaces
    if (pkg.version.find(' ') != std::string::npos) {
        return {"Format validation", TestStatus::FAIL, "Version contains spaces: " + pkg.version};
    }

    return {"Format validation", TestStatus::PASS, "All required fields present"};
}

// ── Tarball download + verify ─────────────────────────────────────────────────
TestResult test_tarball(const PkgInfo &pkg, const std::string &workdir) {
    std::string dest = workdir + "/" + pkg.name + "-" + pkg.version + ".tar.gz";

    std::cout << "  [~] Downloading " << pkg.url << " ..." << std::endl;

    // Download
    std::string cmd = "curl -fsSL --connect-timeout 15 --max-time 120 "
                      "-o \"" + dest + "\" \"" + pkg.url + "\" 2>&1";
    int ret = system(cmd.c_str());
    if (ret != 0) {
        return {"Tarball download", TestStatus::FAIL,
                "curl failed (exit " + std::to_string(ret) + ") for: " + pkg.url};
    }

    if (!fs::exists(dest) || fs::file_size(dest) == 0) {
        return {"Tarball download", TestStatus::FAIL, "Downloaded file is empty"};
    }

    // Detect archive type and verify integrity
    std::string ext = pkg.url;
    std::string verify_cmd;
    if      (ext.find(".tar.gz")  != std::string::npos || ext.find(".tgz") != std::string::npos)
        verify_cmd = "tar -tzf \"" + dest + "\" > /dev/null 2>&1";
    else if (ext.find(".tar.bz2") != std::string::npos || ext.find(".tbz") != std::string::npos)
        verify_cmd = "tar -tjf \"" + dest + "\" > /dev/null 2>&1";
    else if (ext.find(".tar.xz")  != std::string::npos)
        verify_cmd = "tar -tJf \"" + dest + "\" > /dev/null 2>&1";
    else if (ext.find(".zip")     != std::string::npos)
        verify_cmd = "unzip -t \"" + dest + "\" > /dev/null 2>&1";
    else
        verify_cmd = "file \"" + dest + "\" > /dev/null 2>&1";

    if (system(verify_cmd.c_str()) != 0) {
        return {"Tarball download", TestStatus::FAIL,
                "Archive integrity check failed — may be corrupt or wrong format"};
    }

    auto size = fs::file_size(dest);
    return {"Tarball download", TestStatus::PASS,
            "Downloaded and verified (" + std::to_string(size / 1024) + " KB)"};
}

// ── Dependency check against local pkg directory ──────────────────────────────
TestResult test_deps(const PkgInfo &pkg, const std::string &pkg_dir) {
    if (pkg.depends.empty())
        return {"Dependency check", TestStatus::SKIP, "No dependencies declared"};

    // Build index of available package names from .pkg files in pkg_dir
    std::set<std::string> available;
    if (!pkg_dir.empty() && fs::exists(pkg_dir)) {
        for (const auto &entry : fs::recursive_directory_iterator(pkg_dir)) {
            if (entry.path().extension() == ".pkg") {
                // Read just the name field
                std::ifstream f(entry.path());
                std::string line;
                while (std::getline(f, line)) {
                    if (line.substr(0, 7) == "name = ") {
                        std::string n = line.substr(7);
                        if (n.size() >= 2 && n.front() == '"' && n.back() == '"')
                            n = n.substr(1, n.size() - 2);
                        available.insert(n);
                        break;
                    }
                }
            }
        }
    }

    std::vector<std::string> missing;
    for (const auto &dep : pkg.depends)
        if (!available.count(dep))
            missing.push_back(dep);

    if (missing.empty()) {
        return {"Dependency check", TestStatus::PASS,
                "All " + std::to_string(pkg.depends.size()) + " deps found in package dir"};
    }

    std::string msg = std::to_string(missing.size()) + " missing: ";
    for (size_t i = 0; i < missing.size(); i++) {
        if (i) msg += ", ";
        msg += missing[i];
    }
    // Missing deps are a warning, not a hard fail — they might just not be converted yet
    return {"Dependency check", TestStatus::WARN, msg};
}

// ── Chroot install test ───────────────────────────────────────────────────────
TestResult test_chroot(const PkgInfo &pkg, const std::string &workdir) {
    if (geteuid() != 0) {
        return {"Chroot install", TestStatus::SKIP,
                "Skipped — not running as root (re-run with sudo to enable)"};
    }

    std::string chrootdir = workdir + "/chroot_" + pkg.name;
    std::string srcdir    = workdir + "/src_" + pkg.name;

    // Minimal chroot skeleton
    for (const auto &d : {"bin","lib","lib64","usr/bin","usr/lib","usr/include",
                           "usr/share","etc","tmp","var/log","dev","proc","sys"}) {
        fs::create_directories(chrootdir + "/" + d);
    }

    // Download & extract tarball into srcdir
    std::string tarball = workdir + "/" + pkg.name + "-" + pkg.version + ".tar.gz";
    if (!fs::exists(tarball)) {
        std::string cmd = "curl -fsSL --connect-timeout 15 --max-time 120 "
                          "-o \"" + tarball + "\" \"" + pkg.url + "\" 2>&1";
        if (system(cmd.c_str()) != 0)
            return {"Chroot install", TestStatus::FAIL, "Could not download tarball for chroot test"};
    }

    fs::create_directories(srcdir);
    std::string extract = "tar -xf \"" + tarball + "\" -C \"" + srcdir + "\" --strip-components=1 2>&1";
    if (system(extract.c_str()) != 0)
        return {"Chroot install", TestStatus::FAIL, "Failed to extract tarball"};

    // Copy essential host binaries into chroot so the script can run
    std::string setup =
        "cp /bin/sh \""    + chrootdir + "/bin/sh\" 2>/dev/null; "
        "cp /bin/cp \""    + chrootdir + "/bin/cp\" 2>/dev/null; "
        "cp /bin/mkdir \"" + chrootdir + "/bin/mkdir\" 2>/dev/null; "
        "cp /bin/chmod \"" + chrootdir + "/bin/chmod\" 2>/dev/null; "
        "cp /bin/cat \""   + chrootdir + "/bin/cat\" 2>/dev/null; "
        "cp /bin/find \""  + chrootdir + "/bin/find\" 2>/dev/null; "
        "cp /bin/ls \""    + chrootdir + "/bin/ls\" 2>/dev/null; "
        // Copy host libs needed by those binaries
        "cp /lib/x86_64-linux-gnu/libc.so.6 \"" + chrootdir + "/lib/\" 2>/dev/null; "
        "cp /lib64/ld-linux-x86-64.so.2 \""     + chrootdir + "/lib64/\" 2>/dev/null; "
        "true";
    (void)system(setup.c_str());

    // Mount /dev and /proc into chroot
    (void)system(("mount --bind /dev \""  + chrootdir + "/dev\" 2>/dev/null").c_str());
    (void)system(("mount --bind /proc \"" + chrootdir + "/proc\" 2>/dev/null").c_str());

    // Copy extracted source into chroot
    std::string chroot_src = chrootdir + "/tmp/src";
    fs::create_directories(chroot_src);
    (void)system(("cp -r \"" + srcdir + "/\"* \"" + chroot_src + "/\" 2>/dev/null").c_str());

    // Write install script into chroot
    std::string script_path = chrootdir + "/tmp/install.sh";
    {
        std::ofstream sf(script_path);
        sf << "#!/bin/sh\nset -e\ncd /tmp/src\n";
        sf << pkg.install_script;
    }
    (void)system(("chmod +x \"" + script_path + "\"").c_str());

    // Run in chroot with timeout
    std::string log = workdir + "/" + pkg.name + "_chroot.log";
    std::string chroot_cmd = "timeout 120 chroot \"" + chrootdir +
                             "\" /bin/sh /tmp/install.sh > \"" + log + "\" 2>&1";
    int ret = system(chroot_cmd.c_str());

    // Unmount
    (void)system(("umount \"" + chrootdir + "/dev\"  2>/dev/null").c_str());
    (void)system(("umount \"" + chrootdir + "/proc\" 2>/dev/null").c_str());

    // Cleanup chroot (keep log)
    fs::remove_all(chrootdir);
    fs::remove_all(srcdir);

    if (ret == 124)
        return {"Chroot install", TestStatus::FAIL, "Script timed out after 120s. Log: " + log};
    if (ret != 0) {
        // Read last few lines of log for context
        std::ifstream lf(log);
        std::vector<std::string> lines;
        std::string l;
        while (std::getline(lf, l)) lines.push_back(l);
        std::string tail;
        for (size_t i = lines.size() > 5 ? lines.size() - 5 : 0; i < lines.size(); i++)
            tail += "\n    " + lines[i];
        return {"Chroot install", TestStatus::FAIL,
                "Script failed (exit " + std::to_string(ret) + "). Last output:" + tail};
    }

    return {"Chroot install", TestStatus::PASS, "Install script completed successfully. Log: " + log};
}