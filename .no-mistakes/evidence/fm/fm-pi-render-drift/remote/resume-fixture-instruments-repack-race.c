#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

struct interpose { const void *replacement; const void *original; };
#define INTERPOSE(newfn, oldfn) \
    __attribute__((used)) static const struct interpose interpose_##oldfn \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(newfn), (const void *)(oldfn) }

static void before_read(const char *path, const char *operation) {
    const char *object = getenv("FM_LIVE_REPACK_OBJECT");
    const char *marker = getenv("FM_LIVE_REPACK_MARKER");
    static int triggered;
    if (triggered || !object || !marker || !path) return;
    char absolute[PATH_MAX];
    if (!realpath(path, absolute) || strcmp(absolute, object)) return;
    triggered = 1;
    int fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        if (errno == EEXIST) return;
        _exit(125);
    }
    struct timeval began;
    gettimeofday(&began, NULL);
    dprintf(fd, "selected_object=%s\noperation=%s\nreader_pid=%d\nreader_program=%s\nstarted=%ld.%06d\n", object, operation, getpid(), getprogname(), began.tv_sec, began.tv_usec);
    fsync(fd);
    pid_t child = fork();
    if (child == 0) {
        unsetenv("DYLD_INSERT_LIBRARIES");
        unsetenv("DYLD_FORCE_FLAT_NAMESPACE");
        unsetenv("GIT_DIR");
        unsetenv("GIT_WORK_TREE");
        unsetenv("GIT_OBJECT_DIRECTORY");
        unsetenv("GIT_ALTERNATE_OBJECT_DIRECTORIES");
        unsetenv("GIT_EXEC_PATH");
        execl("/usr/bin/git", "git", "-C", getenv("FM_LIVE_REPACK_ROOT"), "repack", "-ad", (char *)NULL);
        _exit(125);
    }
    int status;
    if (child < 0 || waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) _exit(125);
    struct stat st;
    if (lstat(object, &st) == 0 || errno != ENOENT) _exit(125);
    struct timeval ended;
    gettimeofday(&ended, NULL);
    dprintf(fd, "repack_exit=0\nloose_object_removed=1\nfinished=%ld.%06d\n", ended.tv_sec, ended.tv_usec);
    if (close(fd) != 0) _exit(125);
}

static int live_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int);
        va_end(args);
    }
    before_read(path, "open");
    return open(path, flags, mode);
}
INTERPOSE(live_open, open);

static int live_openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int);
        va_end(args);
    }
    if (path && path[0] == '/') before_read(path, "openat");
    return openat(dirfd, path, flags, mode);
}
INTERPOSE(live_openat, openat);

static int live_link(const char *source, const char *destination) {
    before_read(source, "link");
    return link(source, destination);
}
INTERPOSE(live_link, link);
