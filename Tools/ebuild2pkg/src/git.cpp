#include "ebuild.h"
#include <iostream>
#include <sstream>
#include <cstdlib>
#include <filesystem>
#include <vector>
#include <string>

namespace fs = std::filesystem;

// Run a shell command inside the repo root.
// Returns true on success.
static bool git_run(const std::string &repo_root, const std::string &subcmd) {
    std::string cmd = "git -C \"" + repo_root + "\" " + subcmd;
    std::cout << "[git] " << cmd << "\n";
    return system(cmd.c_str()) == 0;
}

// Stage all changed/new files in the output directory and the INDEX,
// then commit and push.
//
// changed_relpaths — repo-relative paths of .pkg files written this run
// index_relpath    — repo-relative path to the INDEX file (usually just "INDEX")
// branch           — branch to push to (default "main")
bool git_commit_and_push(
    const std::string              &repo_root,
    const std::vector<std::string> &changed_relpaths,
    const std::string              &index_relpath,
    const std::string              &branch)
{
    if (repo_root.empty()) {
        std::cerr << "[git] No repo root set — use --repo <path>\n";
        return false;
    }

    if (changed_relpaths.empty()) {
        std::cout << "[git] Nothing new to commit\n";
        return true;
    }

    // Make sure the remote is reachable before we do any local work.
    // A dry-run ls-remote is the cheapest connectivity check.
    if (!git_run(repo_root, "ls-remote --exit-code origin HEAD > /dev/null 2>&1")) {
        std::cerr << "[git] Cannot reach remote — aborting commit\n";
        return false;
    }

    // Pull latest to reduce chance of a push conflict
    if (!git_run(repo_root, "pull --rebase origin " + branch)) {
        std::cerr << "[git] Pull/rebase failed — resolve conflicts manually\n";
        return false;
    }

    // Stage each changed pkg file
    for (const auto &rp : changed_relpaths) {
        std::string full = repo_root + "/" + rp;
        if (!fs::exists(full)) {
            std::cerr << "[git] Skipping missing file: " << rp << "\n";
            continue;
        }
        git_run(repo_root, "add \"" + rp + "\"");
    }

    // Stage the updated INDEX
    git_run(repo_root, "add \"" + index_relpath + "\"");

    // Check whether there's actually anything staged
    if (system(("git -C \"" + repo_root + "\" diff --cached --quiet").c_str()) == 0) {
        std::cout << "[git] Nothing staged — index and pkg files already up to date\n";
        return true;
    }

    // Build a commit message summarising what changed
    std::ostringstream msg;
    msg << "ebuild2pkg: add/update " << changed_relpaths.size() << " package";
    if (changed_relpaths.size() != 1) msg << "s";
    msg << "\n\n";
    for (const auto &rp : changed_relpaths)
        msg << "  " << rp << "\n";

    std::string escaped_msg = msg.str();
    // Escape double-quotes in the message for the shell
    size_t pos = 0;
    while ((pos = escaped_msg.find('"', pos)) != std::string::npos) {
        escaped_msg.replace(pos, 1, "\\\"");
        pos += 2;
    }

    if (!git_run(repo_root, "commit -m \"" + escaped_msg + "\"")) {
        std::cerr << "[git] Commit failed\n";
        return false;
    }

    if (!git_run(repo_root, "push origin " + branch)) {
        std::cerr << "[git] Push failed — you may need to push manually\n";
        return false;
    }

    std::cout << "[git] Pushed " << changed_relpaths.size() << " file(s) to "
              << branch << "\n";
    return true;
}
