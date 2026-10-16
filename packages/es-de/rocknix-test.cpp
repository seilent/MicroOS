#include "RocknixGamelist.h"
#include "utils/FileSystemUtil.h"
#include "utils/TimeUtil.h"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

static int failures {0};

static void check(const bool ok, const std::string& what)
{
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", what.c_str());
        ++failures;
    }
}

static void expect(const std::string& got, const std::string& want, const std::string& what)
{
    check(got == want, what + ": got \"" + got + "\", want \"" + want + "\"");
}

static void writeFile(const std::string& path, const std::string& content)
{
    std::ofstream(path) << content;
}

static std::string readFile(const std::string& path)
{
    std::ifstream file {path};
    std::stringstream content;
    content << file.rdbuf();
    return content.str();
}

static void makeDirs(const std::string& path)
{
    check(Utils::FileSystem::createDirectory(path), "mkdir " + path);
}

static pugi::xml_node parse(pugi::xml_document& doc, const std::string& xml)
{
    check(static_cast<bool>(doc.load_string(xml.c_str())), "parse " + xml);
    return doc.first_child();
}

static void testKeepUnknown()
{
    const std::vector<std::string> declNames {
        "name",     "sortname",    "collectionsortname", "desc",          "rating",
        "releasedate", "developer", "publisher",         "genre",         "players",
        "favorite", "completed",   "kidgame",            "hidden",        "broken",
        "nogamecount", "nomultiscrape", "hidemetadata",  "playcount",     "playtime",
        "screen",   "controller",  "altemulator",        "lastplayed"};

    pugi::xml_document oldDoc;
    const pugi::xml_node oldNode {parse(
        oldDoc, "<game id=\"123\"><path>./x.gba</path><name>X</name>"
                "<image>./images/x-image.png</image><thumbnail>./images/x-thumb.png</thumbnail>"
                "<md5>abc</md5><scrap name=\"ScreenScraper\" date=\"20261001T000000\"/>"
                "<playcount>1</playcount></game>")};
    pugi::xml_document newDoc;
    pugi::xml_node newNode {
        parse(newDoc, "<game><name>X</name><playcount>2</playcount></game>")};
    RocknixGamelist::keepUnknown(oldNode, newNode, declNames);
    expect(newNode.attribute("id").value(), "123", "keepUnknown id");
    expect(newNode.child("image").text().get(), "./images/x-image.png", "keepUnknown image");
    expect(newNode.child("thumbnail").text().get(), "./images/x-thumb.png",
           "keepUnknown thumbnail");
    expect(newNode.child("md5").text().get(), "abc", "keepUnknown md5");
    expect(newNode.child("scrap").attribute("name").value(), "ScreenScraper",
           "keepUnknown scrap name");
    expect(newNode.child("scrap").attribute("date").value(), "20261001T000000",
           "keepUnknown scrap date");
    expect(newNode.child("playcount").text().get(), "2", "keepUnknown playcount");
    check(!newNode.child("playcount").next_sibling("playcount"), "keepUnknown one playcount");
    check(!newNode.child("path"), "keepUnknown copies no path");

    pugi::xml_document nameOldDoc;
    const pugi::xml_node nameOld {
        parse(nameOldDoc, "<game><path>./y.gba</path><name>y</name>"
                          "<image>./images/y-image.png</image></game>")};
    pugi::xml_document nameNewDoc;
    pugi::xml_node nameNew {parse(nameNewDoc, "<game><name>y</name></game>")};
    RocknixGamelist::keepUnknown(nameOld, nameNew, declNames);
    check(++nameNew.children().begin() != nameNew.children().end(),
          "keepUnknown default name node keeps more than the name");
    expect(nameNew.child("image").text().get(), "./images/y-image.png",
           "keepUnknown default name node image");
    check(!RocknixGamelist::defaultNameOnly(nameNew, "y"), "defaultNameOnly with ROCKNIX tags");

    pugi::xml_document plainDoc;
    check(RocknixGamelist::defaultNameOnly(parse(plainDoc, "<game><name>y</name></game>"), "y"),
          "defaultNameOnly default name");
    pugi::xml_document renamedDoc;
    check(!RocknixGamelist::defaultNameOnly(parse(renamedDoc, "<game><name>z</name></game>"), "y"),
          "defaultNameOnly other name");
    pugi::xml_document idOldDoc;
    const pugi::xml_node idOld {
        parse(idOldDoc, "<game id=\"7\"><path>./y.gba</path><name>y</name></game>")};
    pugi::xml_document idNewDoc;
    pugi::xml_node idNew {parse(idNewDoc, "<game><name>y</name></game>")};
    RocknixGamelist::keepUnknown(idOld, idNew, declNames);
    check(!RocknixGamelist::defaultNameOnly(idNew, "y"), "defaultNameOnly with an id attribute");
}

static void testGamelistPaths(const std::string& dir)
{
    const std::string roms {dir + "/roms"};
    const std::string gba {roms + "/gba"};
    const std::string microos {dir + "/run/microos"};
    const std::string roms2gba {dir + "/roms2/gba"};
    const std::string appdata {dir + "/appdata/gamelists"};
    makeDirs(gba);
    makeDirs(microos);
    makeDirs(roms2gba);
    makeDirs(appdata + "/gba");
    makeDirs(appdata + "/microos");
    const std::string appGba {appdata + "/gba/gamelist.xml"};
    const std::string appMicroos {appdata + "/microos/gamelist.xml"};
    const std::string appRoms2 {appdata + "/roms2gba/gamelist.xml"};
    writeFile(appGba, "<gameList/>");
    writeFile(appMicroos, "<gameList/>");
    writeFile(microos + "/gamelist.xml", "<gameList/>");
    writeFile(roms2gba + "/gamelist.xml", "<gameList/>");
    const std::string romDirectory {roms + "/"};

    RocknixGamelist::GamelistPaths paths {
        RocknixGamelist::gamelistPaths(gba, romDirectory, appGba, true)};
    expect(paths.read, "", "legacy gba without card file read");
    expect(paths.write, gba + "/gamelist.xml", "legacy gba without card file write");

    paths = RocknixGamelist::gamelistPaths(gba, romDirectory, appGba, false);
    expect(paths.read, appGba, "unpatched gba without card file read");
    expect(paths.write, appGba, "unpatched gba without card file write");

    writeFile(gba + "/gamelist.xml", "<gameList/>");
    paths = RocknixGamelist::gamelistPaths(gba, romDirectory, appGba, true);
    expect(paths.read, gba + "/gamelist.xml", "legacy gba with card file read");
    expect(paths.write, gba + "/gamelist.xml", "legacy gba with card file write");

    paths = RocknixGamelist::gamelistPaths(gba, romDirectory, appGba, false);
    expect(paths.read, appGba, "unpatched gba with card file read");
    expect(paths.write, appGba, "unpatched gba with card file write");

    paths = RocknixGamelist::gamelistPaths(microos, romDirectory, appMicroos, true);
    expect(paths.read, appMicroos, "legacy microos read");
    expect(paths.write, appMicroos, "legacy microos write");

    paths = RocknixGamelist::gamelistPaths(microos, romDirectory, appMicroos, false);
    expect(paths.read, appMicroos, "unpatched microos read");
    expect(paths.write, appMicroos, "unpatched microos write");

    paths = RocknixGamelist::gamelistPaths(roms2gba, romDirectory, appRoms2, true);
    expect(paths.read, "", "legacy roms2/gba read");
    expect(paths.write, appRoms2, "legacy roms2/gba write");

    paths = RocknixGamelist::gamelistPaths(roms2gba, romDirectory, appRoms2, false);
    expect(paths.read, "", "unpatched roms2/gba read");
    expect(paths.write, appRoms2, "unpatched roms2/gba write");

    paths = RocknixGamelist::gamelistPaths(roms, romDirectory, appGba, true);
    expect(paths.read, "", "legacy roms root read");
    expect(paths.write, roms + "/gamelist.xml", "legacy roms root write");
}

static void testSaveGamelist(const std::string& dir)
{
    const std::string system {dir + "/save"};
    makeDirs(system);
    const std::string path {system + "/gamelist.xml"};
    pugi::xml_document doc;
    doc.append_child("gameList").append_child("game").append_child("name").text().set("X");

    check(RocknixGamelist::saveGamelist(doc, path), "saveGamelist writes");
    pugi::xml_document saved;
    check(saved.load_file(path.c_str()) &&
              std::string {saved.child("gameList").child("game").child("name").text().get()} ==
                  "X",
          "saveGamelist content");
    check(!Utils::FileSystem::exists(path + ".tmp"), "saveGamelist leaves no temp file");

    const std::string old {readFile(path)};
    pugi::xml_document changed;
    changed.append_child("gameList").append_child("game").append_child("name").text().set("Y");

    if (geteuid() != 0) {
        chmod(system.c_str(), 0555);
        check(!RocknixGamelist::saveGamelist(changed, path), "saveGamelist read only dir fails");
        chmod(system.c_str(), 0755);
        expect(readFile(path), old, "saveGamelist read only dir keeps the old file");
        check(!Utils::FileSystem::exists(path + ".tmp"), "saveGamelist read only dir no temp");
    }

    check(symlink((dir + "/missing/x").c_str(), (path + ".tmp").c_str()) == 0,
          "symlink dangling temp");
    check(!RocknixGamelist::saveGamelist(changed, path), "saveGamelist unwritable temp fails");
    expect(readFile(path), old, "saveGamelist unwritable temp keeps the old file");
    check(Utils::FileSystem::removeFile(path + ".tmp"), "remove dangling temp");

    const std::string victim {dir + "/victim"};
    writeFile(victim, "victim");
    check(symlink(victim.c_str(), (path + ".tmp").c_str()) == 0, "symlink planted temp");
    check(!RocknixGamelist::saveGamelist(changed, path), "saveGamelist planted temp fails");
    expect(readFile(victim), "victim", "saveGamelist planted temp leaves the target alone");
    expect(readFile(path), old, "saveGamelist planted temp keeps the old file");
    check(Utils::FileSystem::isSymlink(path + ".tmp"), "saveGamelist planted temp link stays");
    check(Utils::FileSystem::removeFile(path + ".tmp"), "remove planted temp");

    makeDirs(path + ".tmp/busy");
    check(!RocknixGamelist::saveGamelist(changed, path), "saveGamelist failed save fails");
    expect(readFile(path), old, "saveGamelist failed save keeps the old file");
    Utils::FileSystem::removeDirectory(path + ".tmp", true);

    const std::string target {system + "/target"};
    makeDirs(target + "/busy");
    check(!RocknixGamelist::saveGamelist(changed, target), "saveGamelist failed rename fails");
    check(!Utils::FileSystem::exists(target + ".tmp"), "saveGamelist failed rename no temp");
    check(Utils::FileSystem::isDirectory(target + "/busy"), "saveGamelist failed rename target");
}

static void testRocknixMedia()
{
    pugi::xml_document gameDoc;
    const pugi::xml_node game {parse(
        gameDoc, "<game><path>./x.gba</path><image>./images/x-image.png</image>"
                 "<thumbnail>./images/x-thumb.png</thumbnail><video>./videos/x-video.mp4</video>"
                 "<marquee>./images/x-marquee.png</marquee><fanart/><md5>abc</md5>"
                 "<playcount>3</playcount></game>")};
    const std::map<std::string, std::string> want {{"image", "./images/x-image.png"},
                                                   {"thumbnail", "./images/x-thumb.png"},
                                                   {"video", "./videos/x-video.mp4"},
                                                   {"marquee", "./images/x-marquee.png"}};
    check(RocknixGamelist::rocknixMedia(game) == want, "rocknixMedia game tags");

    pugi::xml_document folderDoc;
    const pugi::xml_node folder {
        parse(folderDoc, "<folder><path>./sub</path><image>./images/sub.png</image></folder>")};
    const std::map<std::string, std::string> folderWant {{"image", "./images/sub.png"}};
    check(RocknixGamelist::rocknixMedia(folder) == folderWant, "rocknixMedia folder");

    pugi::xml_document noneDoc;
    const pugi::xml_node none {parse(noneDoc, "<game><path>./z.gba</path><md5>x</md5></game>")};
    check(RocknixGamelist::rocknixMedia(none).empty(), "rocknixMedia none");
}

static void testResolveTag(const std::string& dir)
{
    const std::string root {dir + "/media/roms/gba"};
    makeDirs(root + "/images");
    writeFile(root + "/images/x-image.png", "png");
    writeFile(root + "/images/x-wheel.png", "png");
    writeFile(dir + "/media/roms/outside.png", "png");
    makeDirs(dir + "/elsewhere");
    writeFile(dir + "/elsewhere/x-image.png", "png");
    const std::string linkRoot {dir + "/media/roms/gbc"};
    makeDirs(linkRoot);
    check(symlink((dir + "/elsewhere").c_str(), (linkRoot + "/images").c_str()) == 0,
          "symlink images");

    expect(RocknixGamelist::resolveTag(root, "./images/x-image.png"),
           root + "/images/x-image.png", "resolveTag relative");
    expect(RocknixGamelist::resolveTag(root, "./images/none.png"), "", "resolveTag missing");
    expect(RocknixGamelist::resolveTag(root, "../outside.png"), "", "resolveTag parent");
    expect(RocknixGamelist::resolveTag(root, dir + "/elsewhere/x-image.png"), "",
           "resolveTag absolute outside");
    expect(RocknixGamelist::resolveTag(root, "./images"), "", "resolveTag directory");
    expect(RocknixGamelist::resolveTag(linkRoot, "./images/x-image.png"), "",
           "resolveTag symlink out");

    const std::map<std::string, std::string> media {{"image", "./images/x-image.png"},
                                                    {"marquee", "./images/none.png"},
                                                    {"wheel", "./images/x-wheel.png"},
                                                    {"thumbnail", "../outside.png"},
                                                    {"fanart", "/storage/roms/gba/images/x-image.png"},
                                                    {"boxback", "/storage/roms/psx/x-image.png"}};
    expect(RocknixGamelist::displayMedia(root, media, "screenshot"),
           root + "/images/x-image.png", "displayMedia screenshot");
    expect(RocknixGamelist::displayMedia(root, media, "marquee"), root + "/images/x-wheel.png",
           "displayMedia marquee falls back to wheel");
    expect(RocknixGamelist::displayMedia(root, media, "cover"), "", "displayMedia cover outside");
    expect(RocknixGamelist::displayMedia(root, media, "3dbox"), "", "displayMedia 3dbox");
    expect(RocknixGamelist::displayMedia(root, media, "fanart"), root + "/images/x-image.png",
           "displayMedia absolute ROCKNIX path");
    expect(RocknixGamelist::displayMedia(root, media, "backcover"), "",
           "displayMedia absolute path of another system");
}

static void testNormalizeRomPath()
{
    const std::string root {"/run/media/micro/card/roms/gba"};
    expect(RocknixGamelist::normalizeRomPath("/storage/roms/gba/x.gba", root), "./x.gba",
           "normalizeRomPath absolute");
    expect(RocknixGamelist::normalizeRomPath("/storage/roms/gba/sub/x.gba", root),
           "./sub/x.gba", "normalizeRomPath subfolder");
    expect(RocknixGamelist::normalizeRomPath("./x.gba", root), "./x.gba",
           "normalizeRomPath relative");
    expect(RocknixGamelist::normalizeRomPath("/other/x.gba", root), "/other/x.gba",
           "normalizeRomPath other");
    expect(RocknixGamelist::normalizeRomPath("/storage/roms/psx/x.gba", root),
           "/storage/roms/psx/x.gba", "normalizeRomPath other system");
}

static time_t rocknixReadTime(const std::string& value)
{
    tm parsed {};
    parsed.tm_isdst = -1;
    if (strptime(value.c_str(), "%Y%m%dT%H%M%S", &parsed) == nullptr)
        return -1;
    return mktime(&parsed);
}

static void testRoundTrip()
{
    pugi::xml_document rocknixDoc;
    const pugi::xml_node rocknix {parse(
        rocknixDoc, "<game><path>./x.gba</path><rating>0.8</rating>"
                    "<releasedate>19950811T000000</releasedate>"
                    "<lastplayed>20261016T123456</lastplayed><playcount>3</playcount>"
                    "<favorite>true</favorite></game>")};

    for (const char* tag : {"releasedate", "lastplayed"}) {
        const std::string value {rocknix.child(tag).text().get()};
        const time_t esde {Utils::Time::stringToTime(value)};
        check(esde == rocknixReadTime(value), std::string {tag} + " read the same: " + value);
        const std::string esdeWritten {Utils::Time::DateTime(esde).getIsoString()};
        expect(esdeWritten, value, std::string {tag} + " written back");
        check(rocknixReadTime(esdeWritten) == esde,
              std::string {tag} + " read back by rocknix: " + esdeWritten);
    }

    const float esdeRating {std::round(std::stof(rocknix.child("rating").text().get()) / 0.1f) /
                            10.0f};
    check(esdeRating == 0.8f, "rating read by ES-DE");
    std::stringstream esdeRatingWritten;
    esdeRatingWritten << esdeRating;
    check(std::strtof(esdeRatingWritten.str().c_str(), nullptr) == 0.8f,
          "rating read back by rocknix: " + esdeRatingWritten.str());

    const int esdePlaycount {std::atoi(rocknix.child("playcount").text().get()) + 1};
    check(esdePlaycount == 4, "playcount read by ES-DE");
    const std::string esdePlaycountWritten {std::to_string(static_cast<long long>(esdePlaycount))};
    check(std::atoi(esdePlaycountWritten.c_str()) == 4,
          "playcount read back by rocknix: " + esdePlaycountWritten);

    const bool esdeFavorite {std::string {rocknix.child("favorite").text().get()} == "true"};
    check(esdeFavorite, "favorite read by ES-DE");
    pugi::xml_document esdeDoc;
    pugi::xml_node esdeGame {esdeDoc.append_child("game")};
    esdeGame.append_child("favorite").text().set(esdeFavorite ? "true" : "false");
    esdeGame.append_child("hidden").text().set("false");
    for (const char* tag : {"favorite", "hidden"}) {
        std::string rocknixRead {esdeGame.child(tag).text().get()};
        for (char& c : rocknixRead)
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        check((rocknixRead == "true") == (std::string {tag} == "favorite"),
              std::string {tag} + " read back by rocknix: " + rocknixRead);
    }
}

int main(int argc, char** argv)
{
    if (argc != 2) {
        std::fprintf(stderr, "usage: rocknix-test <dir>\n");
        return 2;
    }
    const std::string dir {Utils::FileSystem::getCanonicalPath(argv[1])};
    testKeepUnknown();
    testGamelistPaths(dir);
    testSaveGamelist(dir);
    testRocknixMedia();
    testResolveTag(dir);
    testNormalizeRomPath();
    testRoundTrip();
    if (failures == 0)
        std::printf("rocknix-test: all cases pass\n");
    return failures == 0 ? 0 : 1;
}
