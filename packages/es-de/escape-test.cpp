#include "utils/FileSystemUtil.h"

#include <cstdio>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

static std::string shell(const std::string& command)
{
    std::string out;
    FILE* p {popen((command + " 2>&1").c_str(), "r")};
    if (!p)
        return "popen failed";
    char buf[256];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), p)) > 0)
        out.append(buf, n);
    pclose(p);
    return out;
}

int main(int argc, char** argv)
{
    if (argc != 2) {
        std::fprintf(stderr, "usage: escape-test <dir>\n");
        return 2;
    }
    const std::string dir {argv[1]};
    const std::string canary {dir + "/canary"};
    const std::string hit {dir + "/hit"};
    FILE* script {std::fopen(hit.c_str(), "w")};
    if (!script)
        return 2;
    std::fprintf(script, "#!/bin/sh\n: > '%s'\n", canary.c_str());
    std::fclose(script);
    chmod(hit.c_str(), 0755);
    const std::vector<std::string> names {
        "plain.gba",
        "space name.gba",
        "back`" + hit + "`tick.gba",
        "pipe|" + hit + "|.gba",
        "sub$(" + hit + ").gba",
        "new\n" + hit + "\nline.gba",
        "tab\tname.gba",
        "single';" + hit + ";'.gba",
        "double\"quote\".gba",
        "amp&" + hit + "&.gba",
        "semi;" + hit + ";.gba",
        "redir>" + canary + ".gba",
        "glob*?[a].gba",
        "#hash ~tilde =eq.gba",
        "back\\$(" + hit + ").gba",
        "dollar$HOME${HOME}.gba",
        "bang!hist.gba",
        "utf8 \xc3\xa9\xe3\x81\x82.gba",
    };
    int rc {0};
    for (const std::string& name : names) {
        const std::string path {Utils::FileSystem::getGenericPath(dir + "/" + name)};
        const std::string escaped {Utils::FileSystem::getEscapedPath(path)};
        const std::string got {shell("printf '%s' " + escaped)};
        if (got != path) {
            std::fprintf(stderr, "FAIL: %s escaped as %s gave %s\n", path.c_str(), escaped.c_str(),
                         got.c_str());
            rc = 1;
        }
        struct stat st;
        if (stat(canary.c_str(), &st) == 0) {
            std::fprintf(stderr, "FAIL: %s ran a command\n", path.c_str());
            unlink(canary.c_str());
            rc = 1;
        }
    }
    if (rc == 0)
        std::printf("escape-test: %zu names round trip through /bin/sh, none ran a command\n",
                    names.size());
    return rc;
}
