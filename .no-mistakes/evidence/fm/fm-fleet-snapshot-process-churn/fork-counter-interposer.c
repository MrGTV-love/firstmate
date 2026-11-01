#include <unistd.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define DYLD_INTERPOSE(_r,_e) __attribute__((used)) static struct{const void* r;const void* e;} _interpose_##_e __attribute__((section("__DATA,__interpose")))={(const void*)(unsigned long)&_r,(const void*)(unsigned long)&_e};
static void logit(const char *kind, const char *what){
  const char *p=getenv("FC_LOG"); if(!p) return;
  int fd=open(p,O_WRONLY|O_APPEND|O_CREAT,0600); if(fd<0) return;
  char buf[1200]; int n=snprintf(buf,sizeof buf,"%s %d %s\n",kind,getpid(),what?what:"");
  if(n>0) write(fd,buf,n>(int)sizeof buf?(int)sizeof buf:n); close(fd);
}
pid_t my_fork(void){ pid_t p=fork(); if(p>0){ char b[32]; snprintf(b,32,"%d",p); logit("fork",b);} return p; }
DYLD_INTERPOSE(my_fork, fork)
int my_execve(const char *path, char *const argv[], char *const envp[]){
  logit("exec",path);
  const char *fb=getenv("FC_BASH");
  if(fb){ int fd=open(path,O_RDONLY); if(fd>=0){ char h[32]={0}; read(fd,h,20); close(fd);
    if(strncmp(h,"#!/usr/bin/env bash",19)==0){ int n=0; while(argv[n]) n++;
      char **nv=calloc(n+2,sizeof(char*)); nv[0]=(char*)fb; nv[1]=(char*)path; for(int i=1;i<n;i++) nv[i+1]=argv[i];
      return execve(fb,nv,envp);} } }
  return execve(path,argv,envp); }
DYLD_INTERPOSE(my_execve, execve)
int my_posix_spawn(pid_t *pid,const char *path,const posix_spawn_file_actions_t *fa,const posix_spawnattr_t *at,char *const argv[],char *const envp[]){ logit("spawn",path); return posix_spawn(pid,path,fa,at,argv,envp);}
DYLD_INTERPOSE(my_posix_spawn, posix_spawn)
int my_posix_spawnp(pid_t *pid,const char *path,const posix_spawn_file_actions_t *fa,const posix_spawnattr_t *at,char *const argv[],char *const envp[]){ logit("spawnp",path); return posix_spawnp(pid,path,fa,at,argv,envp);}
DYLD_INTERPOSE(my_posix_spawnp, posix_spawnp)
