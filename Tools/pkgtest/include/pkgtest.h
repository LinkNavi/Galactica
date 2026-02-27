#pragma once
#include <string>
#include <vector>

enum class TestStatus { PASS, FAIL, WARN, SKIP };

struct TestResult {
    std::string  name;
    TestStatus   status;
    std::string  message;
};

struct PkgInfo {
    std::string              name;
    std::string              version;
    std::string              description;
    std::string              url;
    std::string              category;
    std::vector<std::string> depends;
    std::string              install_script;
    std::string              filepath;
};

struct TestReport {
    std::string              pkg_name;
    std::string              pkg_file;
    std::vector<TestResult>  results;
    bool                     overall_pass;
};