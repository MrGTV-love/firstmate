/* Stand-in recipient for a restored claude agent: NOT Claude. It names
 * itself claude (process comm), prints a banner, puts its tty in raw mode,
 * and appends every byte it receives to $KEYLOG, so any key or text that a
 * lifecycle consumer sends to the pane is recorded. */
#include <stdio.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
#include <fcntl.h>
int main(int argc, char **argv) {
  const char *log = getenv("KEYLOG");
  struct termios t;
  int fd = -1, i;
  if (log) fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (tcgetattr(0, &t) == 0) { cfmakeraw(&t); tcsetattr(0, TCSANOW, &t); }
  printf("fake-claude ready pid=%d args:", (int)getpid());
  for (i = 1; i < argc; i++) printf(" %s", argv[i]);
  printf("\r\n"); fflush(stdout);
  for (;;) {
    unsigned char b[256]; ssize_t n = read(0, b, sizeof b);
    if (n <= 0) { if (n < 0) continue; pause(); }
    if (fd >= 0) write(fd, b, (size_t)n);
  }
}
