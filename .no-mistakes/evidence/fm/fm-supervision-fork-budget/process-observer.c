#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/types.h>

static void count_start(void) {
    const char *path = getenv("FM_START_LOG");
    if (!path) return;
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd >= 0) { (void)write(fd, "x", 1); close(fd); }
}
static pid_t observed_fork(void) {
    pid_t p = fork();
    if (p > 0) count_start();
    return p;
}
static int observed_spawn(pid_t *pid, const char *path,
    const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attr,
    char *const argv[], char *const envp[]) {
    int rc = posix_spawn(pid, path, actions, attr, argv, envp);
    if (rc == 0) count_start();
    return rc;
}
static int observed_spawnp(pid_t *pid, const char *path,
    const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attr,
    char *const argv[], char *const envp[]) {
    int rc = posix_spawnp(pid, path, actions, attr, argv, envp);
    if (rc == 0) count_start();
    return rc;
}
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *replacement; const void *original; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)replacement, (const void *)original }
INTERPOSE(observed_fork, fork);
INTERPOSE(observed_spawn, posix_spawn);
INTERPOSE(observed_spawnp, posix_spawnp);
