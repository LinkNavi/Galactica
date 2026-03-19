#include "dreamland.h"
#include <algorithm>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <sstream>

// ── base64 ────────────────────────────────────────────────────────────────────

std::string Dreamland::base64_encode(const std::string& in) {
    static const char* b64 =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve(((in.size() + 2) / 3) * 4);
    int val = 0, valb = -6;
    for (unsigned char c : in) {
        val = (val << 8) + c; valb += 8;
        while (valb >= 0) { out.push_back(b64[(val >> valb) & 0x3F]); valb -= 6; }
    }
    if (valb > -6) out.push_back(b64[((val << 8) >> (valb + 8)) & 0x3F]);
    while (out.size() % 4) out.push_back('=');
    return out;
}

std::string Dreamland::base64_decode(const std::string& in) {
    static const int lut[256] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
        52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-1,-1,-1,
        -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
        15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
        41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    };
    std::string out; int val = 0, valb = -8;
    for (unsigned char c : in) {
        if (lut[c] == -1) break;
        val = (val << 6) + lut[c]; valb += 6;
        if (valb >= 0) { out.push_back((val >> valb) & 0xFF); valb -= 8; }
    }
    return out;
}

// ── Package DB (cache) ────────────────────────────────────────────────────────

void Dreamland::save_pkg_db() {
    std::ofstream f(pkg_db);
    if (!f) return;
    for (auto& [n, p] : packages) {
        if (p.source == PackageSource::ARCH_BINARY) {
            std::string deps;
            for (auto& d : p.dependencies) deps += d + " ";
            if (!deps.empty()) deps.pop_back();
            f << "ARCH|" << p.name << "|" << p.version << "|" << p.repo << "|"
              << p.filename << "|" << p.size << "|" << p.description << "|"
              << (p.deps_resolved ? "1" : "0") << "|" << deps << "\n";
        } else if (p.source == PackageSource::GALACTICA) {
            std::string encoded = base64_encode(p.build_script);
            std::string deps;
            for (auto& d : p.dependencies) deps += d + " ";
            if (!deps.empty()) deps.pop_back();
            f << "GALACTICA|" << p.name << "|" << p.version << "|" << p.url << "|"
              << p.category << "|" << p.description << "|" << p.type << "|"
              << encoded << "|" << deps << "\n";
        }
    }
}

void Dreamland::load_pkg_db() {
    std::ifstream f(pkg_db);
    if (!f) return;
    std::string l;
    while (std::getline(f, l)) {
        std::istringstream is(l);
        std::string type; std::getline(is, type, '|');
        if (type == "ARCH") {
            std::string n, v, r, fn, sz, d, dr, deps;
            std::getline(is,n,'|'); std::getline(is,v,'|'); std::getline(is,r,'|');
            std::getline(is,fn,'|'); std::getline(is,sz,'|'); std::getline(is,d,'|');
            std::getline(is,dr,'|'); std::getline(is,deps,'|');
            Package p; p.name=n; p.version=v; p.repo=r; p.filename=fn;
            try { p.size=std::stoull(sz); } catch(...) {}
            p.description=d; p.source=PackageSource::ARCH_BINARY; p.deps_resolved=dr=="1";
            if (!deps.empty()) { std::istringstream ds(deps); std::string dep; while(ds>>dep) p.dependencies.push_back(dep); }
            packages[n] = p;
        } else if (type == "GALACTICA") {
            std::string n, v, u, c, d, t, script, deps;
            std::getline(is,n,'|'); std::getline(is,v,'|'); std::getline(is,u,'|');
            std::getline(is,c,'|'); std::getline(is,d,'|'); std::getline(is,t,'|');
            std::getline(is,script,'|'); std::getline(is,deps,'|');
            Package p; p.name=n; p.version=v; p.url=u; p.category=c;
            p.description=d; p.type=t; p.build_script=base64_decode(script);
            p.source=PackageSource::GALACTICA;
            if (!deps.empty()) { std::istringstream ds(deps); std::string dep; while(ds>>dep) p.dependencies.push_back(dep); }
            packages[n] = p;
        }
    }
}

// ── Installed DB ──────────────────────────────────────────────────────────────

void Dreamland::save_installed() {
    std::ofstream f(installed_db);
    if (!f) return;
    for (auto& [n, p] : installed) {
        std::string src = p.source == PackageSource::MODULE      ? "module"
                        : p.source == PackageSource::GALACTICA   ? "galactica"
                                                                  : "arch";
        f << n << " " << p.version << " " << src << " " << p.type << "\n";
    }
}

void Dreamland::load_installed() {
    std::ifstream f(installed_db);
    if (!f) return;
    std::string l;
    while (std::getline(f, l)) {
        if (l.empty()) continue;
        std::istringstream is(l);
        Package p; std::string src;
        is >> p.name >> p.version >> src >> p.type;
        p.installed = true;
        p.source = src == "module"    ? PackageSource::MODULE
                 : src == "galactica" ? PackageSource::GALACTICA
                                      : PackageSource::ARCH_BINARY;
        installed[p.name] = p;
    }
}

// ── Galactica repo ────────────────────────────────────────────────────────────

bool Dreamland::fetch_galactica() {
    status("Fetching Galactica index...");
    std::string content;
    if (!dl_str(GALACTICA_RAW_URL "INDEX", content)) { err("Failed to fetch INDEX"); return false; }
    std::ofstream(pkg_index) << content;
    galactica_pkgs.clear();
    std::istringstream is(content); std::string l;
    while (std::getline(is, l)) {
        l.erase(0, l.find_first_not_of(" \t\r\n"));
        l.erase(l.find_last_not_of(" \t\r\n") + 1);
        if (!l.empty() && l[0] != '#') galactica_pkgs.insert(l);
    }
    ok(std::to_string(galactica_pkgs.size()) + " Galactica packages");
    return true;
}

bool Dreamland::parse_galactica_pkg(const std::string& pkg_path) {
    std::string content;
    if (!dl_str(GALACTICA_RAW_URL + pkg_path, content)) { dbg("Failed: " + pkg_path); return false; }
    Package p; p.source = PackageSource::GALACTICA;
    std::istringstream iss(content); std::string line, section;
    while (std::getline(iss, line)) {
        line.erase(0, line.find_first_not_of(" \t\r\n"));
        line.erase(line.find_last_not_of(" \t\r\n") + 1);
        if (line.empty() || line[0] == '#') continue;
        if (line[0] == '[' && line.back() == ']') { section = line.substr(1, line.length()-2); continue; }
        if (section == "Script") { if (!p.build_script.empty()) p.build_script += "\n"; p.build_script += line; continue; }
        size_t eq = line.find('='); if (eq == std::string::npos) continue;
        std::string key = line.substr(0, eq), value = line.substr(eq+1);
        key.erase(key.find_last_not_of(" \t")+1);
        value.erase(0, value.find_first_not_of(" \t"));
        if (value.size()>=2 && value[0]=='"' && value.back()=='"') value=value.substr(1,value.size()-2);
        if (section == "Package") {
            if      (key=="name")        p.name=value;
            else if (key=="version")     p.version=value;
            else if (key=="description") p.description=value;
            else if (key=="url")         p.url=value;
            else if (key=="category")    p.category=value;
            else if (key=="type")        p.type=value;
        } else if (section == "Dependencies") {
            if (key=="depends") { std::istringstream ds(value); std::string d; while(ds>>d) p.dependencies.push_back(d); }
        } else if (section == "Build") {
            p.build_flags[key] = value;
        }
    }
    if (!p.name.empty() && !p.version.empty()) { packages[p.name]=p; return true; }
    return false;
}

bool Dreamland::load_galactica_packages() {
    if (galactica_pkgs.empty()) return false;
    int loaded = 0;
    for (const auto& pp : galactica_pkgs) if (parse_galactica_pkg(pp)) loaded++;
    if (loaded > 0) { ok("Loaded " + std::to_string(loaded) + " Galactica packages"); return true; }
    return false;
}

// ── Arch repo ─────────────────────────────────────────────────────────────────

bool Dreamland::parse_arch_db_with_deps(const std::string& db, const std::string& repo) {
    std::string dir = db_cache_dir + "/" + repo;
    std::error_code ec;
    if (fs::exists(dir)) fs::remove_all(dir, ec);
    fs::create_directories(dir);

    std::string tar = fs::exists("/bin/tar") ? "/bin/tar" : "busybox tar";
    if (exec(tar + " -xzf " + db + " -C " + dir + " 2>/dev/null") != 0) {
        err("Failed to extract " + repo + " database"); return false;
    }

    int cnt = 0;
    for (auto& e : fs::directory_iterator(dir)) {
        if (!e.is_directory()) continue;
        std::string desc = e.path().string() + "/desc";
        if (!fs::exists(desc)) continue;
        Package p; p.source=PackageSource::ARCH_BINARY; p.repo=repo;
        std::ifstream f(desc); std::string l, sec;
        while (std::getline(f, l)) {
            l.erase(0, l.find_first_not_of(" \t\r\n"));
            l.erase(l.find_last_not_of(" \t\r\n")+1);
            if (l.empty()) { sec=""; continue; }
            if (l[0]=='%' && l.back()=='%') { sec=l.substr(1,l.size()-2); continue; }
            if      (sec=="NAME")     p.name=l;
            else if (sec=="VERSION")  p.version=l;
            else if (sec=="DESC" && p.description.empty()) p.description=l;
            else if (sec=="FILENAME") p.filename=l;
            else if (sec=="CSIZE")    try { p.size=std::stoull(l); } catch(...) {}
            else if (sec=="DEPENDS") {
                size_t pos = l.find_first_of(">=<");
                std::string dep = pos!=std::string::npos ? l.substr(0,pos) : l;
                size_t so = dep.find(".so");
                if (so!=std::string::npos) dep=dep.substr(0,so);
                if (!dep.empty()) p.dependencies.push_back(dep);
            }
        }
        if (!p.name.empty() && packages.find(p.name)==packages.end()) {
            packages[p.name]=p; cnt++;
        }
    }
    ok(std::to_string(cnt) + " packages from " + repo);
    return cnt > 0;
}

bool Dreamland::sync_arch() {
    status("Syncing Arch databases...");
    for (auto& mirror : ARCH_MIRRORS) {
        bool all_ok = true;
        for (auto& repo : ARCH_REPOS) {
            std::string url  = mirror + "/" + repo + "/os/x86_64/" + repo + ".db";
            std::string file = db_cache_dir + "/" + repo + ".db";
            if (!dl_file(url, file, repo + ".db")) { all_ok=false; break; }
            if (!parse_arch_db_with_deps(file, repo)) { all_ok=false; break; }
        }
        if (all_ok) { ok("Synced from " + mirror); return true; }
        warn("Failed " + mirror + ", trying next...");
    }
    err("All mirrors failed"); return false;
}

// ── Dep resolution ────────────────────────────────────────────────────────────

std::string Dreamland::resolve_lib_to_pkg(const std::string& dep) {
    if (dep.find(".so") != std::string::npos) {
        std::string base = dep.substr(0, dep.find(".so"));
        if (packages.count(base)) return base;
        if (base.size()>3 && base.substr(0,3)=="lib") {
            std::string without = base.substr(3);
            if (packages.count(without)) return without;
        }
        dbg("Could not resolve lib: " + dep);
    }
    return dep;
}

std::vector<std::string> Dreamland::resolve_dependencies(
        const std::string& pkg_name,
        std::set<std::string>& resolved,
        std::set<std::string>& visited) {
    std::vector<std::string> order;
    if (visited.count(pkg_name)) return order;
    visited.insert(pkg_name);
    if (installed.count(pkg_name)) { resolved.insert(pkg_name); return order; }
    auto it = packages.find(pkg_name);
    if (it == packages.end()) { warn("Dep not found: " + pkg_name); return order; }
    for (const auto& dep : it->second.dependencies) {
        std::string rd = resolve_lib_to_pkg(dep);
        if (!resolved.count(rd)) {
            auto sub = resolve_dependencies(rd, resolved, visited);
            order.insert(order.end(), sub.begin(), sub.end());
        }
    }
    if (!resolved.count(pkg_name)) { order.push_back(pkg_name); resolved.insert(pkg_name); }
    return order;
}
