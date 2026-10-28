// Fault plug: make proc_pid_rusage fail for chosen pids, so fm-duration's
// real native Darwin CPU read fails exactly as the intent describes.
// FMLAB_FAIL=root    -> fail pids whose parent is this process (the runner's root)
// FMLAB_FAIL=nonroot -> fail pids whose parent is NOT this process (descendants)
// FMLAB_FAIL=pid:N   -> fail pid N
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <unistd.h>
typedef int (*real_t)(int, int, rusage_info_t *);
static int parent_of(int pid) {
  struct proc_bsdinfo info;
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) return -1;
  return (int)info.pbi_ppid;
}
int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer) {
  static real_t real;
  if (!real) real = (real_t)dlsym(RTLD_NEXT, "proc_pid_rusage");
  const char *mode = getenv("FMLAB_FAIL");
  if (mode && pid != getpid()) {
    int fail = 0;
    if (!strcmp(mode, "root")) fail = parent_of(pid) == getpid();
    else if (!strcmp(mode, "nonroot")) fail = parent_of(pid) != getpid();
    else if (!strncmp(mode, "pid:", 4)) fail = pid == atoi(mode + 4);
    if (fail) { errno = ESRCH; return -1; }
  }
  return real(pid, flavor, buffer);
}
