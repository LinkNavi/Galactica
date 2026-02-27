#include "ebuild.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <regex>
#include <algorithm>

// Strip version/slot/USE specifiers from a dep atom
// e.g. ">=dev-libs/glib-2.0:2[dbus]" -> "dev-libs/glib"
static std::string strip_atom(const std::string &atom) {
    std::string s = atom;

    // Remove leading version operators
    size_t i = 0;
    while (i < s.size() && (s[i] == '>' || s[i] == '<' || s[i] == '=' || s[i] == '!' || s[i] == '~'))
        i++;
    s = s.substr(i);

    // Remove USE flags [...]
    size_t bracket = s.find('[');
    if (bracket != std::string::npos) s = s.substr(0, bracket);

    // Remove slot :N
    size_t colon = s.find(':');
    if (colon != std::string::npos) {
        // Keep slot if it's meaningful (e.g. gtk+:3) — we'll look it up with slot
        // For now keep it so the mapping table can match "x11-libs/gtk+:3"
    }

    // Remove version suffix -X.Y.Z (only if there's a category/)
    if (s.find('/') != std::string::npos) {
        // Pattern: category/name-VERSION where VERSION starts with digit
        std::regex ver_re(R"((/[a-zA-Z0-9_+.-]+?)(-\d[\d.a-zA-Z_-]*)$)");
        s = std::regex_replace(s, ver_re, "$1");
    }

    return s;
}

// Parse a dep string, skipping USE conditionals and || groups, returning atom list
static std::vector<std::string> parse_dep_string(const std::string &depstr) {
    std::vector<std::string> atoms;
    std::istringstream ss(depstr);
    std::string tok;
    int depth = 0;

    while (ss >> tok) {
        if (tok == "(" || tok.back() == '(') { depth++; continue; }
        if (tok == ")" || tok == ")") { if (depth > 0) depth--; continue; }
        if (tok == "||") continue;
        // USE conditional: "flag? (" or "!flag? ("
        if (tok.back() == '?' ) continue;
        // Skip pure virtual deps
        if (tok.find("virtual/") == 0) continue;

        std::string atom = strip_atom(tok);
        if (!atom.empty() && atom.find('/') != std::string::npos)
            atoms.push_back(atom);
    }
    return atoms;
}

// Read a multi-line variable value from ebuild (handles line continuations)
static std::string read_variable(std::istream &file, const std::string &first_line) {
    std::string result;
    char quote_char = 0;

    // Check if value is on same line
    size_t eq = first_line.find('=');
    if (eq == std::string::npos) return "";

    std::string val = first_line.substr(eq + 1);
    // Trim
    val.erase(0, val.find_first_not_of(" \t"));

    // Single-line: no quotes or closed on same line
    if (!val.empty() && (val[0] == '"' || val[0] == '\'')) {
        quote_char = val[0];
        val = val.substr(1);
        size_t close = val.find(quote_char);
        if (close != std::string::npos) {
            return val.substr(0, close);
        }
        result = val + " ";
    } else {
        // No quotes — single token or heredoc
        return val;
    }

    // Multi-line: read until closing quote
    std::string line;
    while (std::getline(file, line)) {
        size_t close = line.find(quote_char);
        if (close != std::string::npos) {
            result += line.substr(0, close);
            break;
        }
        result += line + " ";
    }
    return result;
}

Ebuild parse_ebuild_file(const std::string &filepath, const std::string &name_hint, const std::string &ver_hint) {
    Ebuild eb;
    eb.name    = name_hint;
    eb.version = ver_hint;

    std::ifstream f(filepath);
    if (!f.is_open()) {
        std::cerr << "[ebuild2pkg] Cannot open: " << filepath << std::endl;
        return eb;
    }

    std::string line;
    std::string rdepend_raw, depend_raw;

    while (std::getline(f, line)) {
        // Trim
        line.erase(0, line.find_first_not_of(" \t"));
        if (line.empty() || line[0] == '#') continue;

        auto starts = [&](const std::string &prefix) {
            return line.substr(0, prefix.size()) == prefix;
        };

        if (starts("DESCRIPTION="))  eb.description = read_variable(f, line);
        else if (starts("HOMEPAGE=")) eb.homepage    = read_variable(f, line);
        else if (starts("SRC_URI="))  eb.src_uri     = read_variable(f, line);
        else if (starts("RDEPEND="))  rdepend_raw    = read_variable(f, line);
        else if (starts("DEPEND="))   depend_raw     = read_variable(f, line);
        else if (starts("BDEPEND="))  {} // ignore build-only deps
    }

    // Infer name/version from filename if not provided
    if (eb.name.empty() || eb.version.empty()) {
        size_t slash = filepath.rfind('/');
        std::string fname = (slash != std::string::npos) ? filepath.substr(slash + 1) : filepath;
        // Remove .ebuild
        if (fname.size() > 7 && fname.substr(fname.size() - 7) == ".ebuild")
            fname = fname.substr(0, fname.size() - 7);
        // Split name-version: last component starting with digit is version
        size_t dash = fname.rfind('-');
        while (dash != std::string::npos && !isdigit(fname[dash + 1]))
            dash = fname.rfind('-', dash - 1);
        if (dash != std::string::npos) {
            eb.version = fname.substr(dash + 1);
            eb.name    = fname.substr(0, dash);
        } else {
            eb.name = fname;
        }
    }

    // Expand ${PV}, ${P}, ${PN} in SRC_URI
    auto replace_var = [&](std::string &s, const std::string &var, const std::string &val) {
        std::string pat = "${" + var + "}";
        size_t pos;
        while ((pos = s.find(pat)) != std::string::npos)
            s.replace(pos, pat.size(), val);
    };
    replace_var(eb.src_uri, "PV", eb.version);
    replace_var(eb.src_uri, "PN", eb.name);
    replace_var(eb.src_uri, "P",  eb.name + "-" + eb.version);

    // Pick first URL from SRC_URI (may have multiple)
    {
        std::istringstream ss(eb.src_uri);
        std::string tok;
        while (ss >> tok) {
            if (tok.substr(0, 7) == "http://" || tok.substr(0, 8) == "https://") {
                eb.src_uri = tok;
                break;
            }
        }
    }

    eb.rdepend = parse_dep_string(rdepend_raw);
    eb.depend  = parse_dep_string(depend_raw);

    return eb;
}