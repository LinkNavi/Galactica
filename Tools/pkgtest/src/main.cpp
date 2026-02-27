#include "pkgtest.h"
#include <filesystem>
#include <iostream>
#include <vector>
#include <string>

namespace fs = std::filesystem;

// Forward declarations
PkgInfo    parse_pkg_file(const std::string &filepath);
TestResult test_format(const PkgInfo &pkg);
TestResult test_tarball(const PkgInfo &pkg, const std::string &workdir);
TestResult test_deps(const PkgInfo &pkg, const std::string &pkg_dir);
TestResult test_chroot(const PkgInfo &pkg, const std::string &workdir);

static void print_usage(const char *argv0) {
    std::cerr << "Usage:\n"
              << "  " << argv0 << " <pkg_file_or_dir> [options]\n"
              << "\nOptions:\n"
              << "  -p <pkg_dir>    Directory of .pkg files for dep checking (default: same dir as input)\n"
              << "  -w <workdir>    Working directory for downloads/chroot (default: /tmp/pkgtest)\n"
              << "  --no-download   Skip tarball download test\n"
              << "  --no-chroot     Skip chroot install test\n"
              << "  --no-deps       Skip dependency check\n"
              << "\nExamples:\n"
              << "  " << argv0 << " mypackage-1.0.0.pkg\n"
              << "  " << argv0 << " ./packages/ -p ./packages/\n"
              << "  sudo " << argv0 << " mypackage-1.0.0.pkg  # enables chroot test\n";
}

static const char *status_str(TestStatus s) {
    switch (s) {
        case TestStatus::PASS: return "\033[32mPASS\033[0m";
        case TestStatus::FAIL: return "\033[31mFAIL\033[0m";
        case TestStatus::WARN: return "\033[33mWARN\033[0m";
        case TestStatus::SKIP: return "\033[90mSKIP\033[0m";
    }
    return "????";
}

static void print_report(const TestReport &report) {
    std::cout << "\n┌─ " << report.pkg_file << "\n";
    for (const auto &r : report.results) {
        std::cout << "│  [" << status_str(r.status) << "] "
                  << r.name << " — " << r.message << "\n";
    }
    std::cout << "└─ "
              << (report.overall_pass ? "\033[32mOVERALL: PASS\033[0m"
                                      : "\033[31mOVERALL: FAIL\033[0m")
              << "\n";
}

static TestReport run_tests(const PkgInfo &pkg, const std::string &workdir,
                             const std::string &pkg_dir,
                             bool do_download, bool do_chroot, bool do_deps) {
    TestReport report;
    report.pkg_name = pkg.name;
    report.pkg_file = pkg.filepath;

    // 1. Format
    auto fmt = test_format(pkg);
    report.results.push_back(fmt);

    // Stop here if format is broken — other tests won't work
    if (fmt.status == TestStatus::FAIL) {
        report.overall_pass = false;
        return report;
    }

    // 2. Tarball
    if (do_download) {
        report.results.push_back(test_tarball(pkg, workdir));
    }

    // 3. Deps
    if (do_deps) {
        report.results.push_back(test_deps(pkg, pkg_dir));
    }

    // 4. Chroot
    if (do_chroot) {
        report.results.push_back(test_chroot(pkg, workdir));
    }

    // Overall: fail if any FAIL result
    report.overall_pass = true;
    for (const auto &r : report.results)
        if (r.status == TestStatus::FAIL) { report.overall_pass = false; break; }

    return report;
}

int main(int argc, char *argv[]) {
    if (argc < 2) { print_usage(argv[0]); return 1; }

    std::string input;
    std::string pkg_dir;
    std::string workdir = "/tmp/pkgtest";
    bool do_download = true;
    bool do_chroot   = true;
    bool do_deps     = true;

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if      (arg == "-p" && i + 1 < argc) pkg_dir = argv[++i];
        else if (arg == "-w" && i + 1 < argc) workdir = argv[++i];
        else if (arg == "--no-download")       do_download = false;
        else if (arg == "--no-chroot")         do_chroot   = false;
        else if (arg == "--no-deps")           do_deps     = false;
        else if (arg[0] != '-')                input = arg;
        else { std::cerr << "Unknown option: " << arg << std::endl; return 1; }
    }

    if (input.empty()) { print_usage(argv[0]); return 1; }

    fs::create_directories(workdir);

    // Collect pkg files to test
    std::vector<std::string> pkg_files;
    if (fs::is_directory(input)) {
        for (const auto &entry : fs::recursive_directory_iterator(input))
            if (entry.path().extension() == ".pkg")
                pkg_files.push_back(entry.path().string());
        if (pkg_dir.empty()) pkg_dir = input;
    } else {
        pkg_files.push_back(input);
        if (pkg_dir.empty()) pkg_dir = fs::path(input).parent_path().string();
    }

    if (pkg_files.empty()) {
        std::cerr << "No .pkg files found in: " << input << std::endl;
        return 1;
    }

    std::cout << "pkgtest — testing " << pkg_files.size() << " package(s)\n";
    std::cout << "Workdir: " << workdir << "\n";
    if (!pkg_dir.empty())
        std::cout << "Pkg dir: " << pkg_dir << "\n";

    int passed = 0, failed = 0;
    for (const auto &f : pkg_files) {
        std::cout << "\nTesting: " << f << std::endl;
        PkgInfo pkg = parse_pkg_file(f);
        if (pkg.name.empty()) {
            std::cerr << "  Failed to parse: " << f << std::endl;
            failed++;
            continue;
        }

        TestReport report = run_tests(pkg, workdir, pkg_dir,
                                      do_download, do_chroot, do_deps);
        print_report(report);
        report.overall_pass ? passed++ : failed++;
    }

    std::cout << "\n══════════════════════════════\n"
              << "Results: \033[32m" << passed << " passed\033[0m, "
              << "\033[31m" << failed << " failed\033[0m"
              << " (" << pkg_files.size() << " total)\n";

    return failed > 0 ? 1 : 0;
}