#include "dreamland.h"
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char* argv[]) {
    Dreamland dl;

    if (argc < 2) { dl.usage(argv[0]); return 1; }

    std::string cmd = argv[1];

    // Module command dispatch
    if (dl.has_cmd(cmd)) return dl.run_cmd(argc, argv) ? 0 : 1;

    // ── Flags ──────────────────────────────────────────────────────────────────
    bool yes       = false;
    bool reinstall = false;
    std::vector<std::string> pkgs;

    for (int i = 2; i < argc; i++) {
        std::string a = argv[i];
        if      (a == "-y" || a == "--yes")        yes       = true;
        else if (a == "--reinstall")               reinstall = true;
        else if (!a.empty() && a[0] != '-')        pkgs.push_back(a);
        else { std::cerr << "Unknown option: " << a << "\n"; return 1; }
    }

    // ── Dispatch ───────────────────────────────────────────────────────────────
    if      (cmd == "sync")                              { dl.sync(); }
    else if (cmd == "install"   && !pkgs.empty())        { return dl.install_multi(pkgs, reinstall, yes) ? 0 : 1; }
    else if (cmd == "uninstall" && !pkgs.empty())        { return dl.uninstall(pkgs[0]) ? 0 : 1; }
    else if (cmd == "upgrade")                           { dl.upgrade(); }
    else if (cmd == "search"    && !pkgs.empty())        { dl.search(pkgs[0]); }
    else if (cmd == "info"      && !pkgs.empty())        { dl.info(pkgs[0]); }
    else if (cmd == "files"     && !pkgs.empty())        { dl.files(pkgs[0]); }
    else if (cmd == "list")                              { dl.list(); }
    else if (cmd == "clean")                             { dl.clean(); }
    else if (cmd == "modules")                           { dl.list_mods(); }
    else                                                 { dl.usage(argv[0]); return 1; }

    return 0;
}
