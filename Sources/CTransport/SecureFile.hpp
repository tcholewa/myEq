#pragma once
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/acl.h>
#include <unistd.h>
#include <vector>

namespace meq {
// Control/installation paths only. Never called by the audio thread.
struct FD {
  int value=-1;
  explicit FD(int v=-1):value(v){}
  ~FD(){if(value>=0)close(value);}
  FD(const FD&)=delete; FD& operator=(const FD&)=delete;
};
inline bool noACL(int fd) {
  acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
  if(!acl)return errno==ENOENT||errno==ENOTSUP;
  acl_entry_t entry;int result=acl_get_entry(acl,ACL_FIRST_ENTRY,&entry);
  acl_free(acl);return result!=0;
}
inline NSData *readFile(const char *path,size_t limit,uid_t owner) {
  FD fd(open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK));
  struct stat st{};
  if(fd.value<0||fstat(fd.value,&st)||!S_ISREG(st.st_mode)||st.st_uid!=owner||
     (st.st_mode&0022)||st.st_nlink!=1||st.st_size<0||uint64_t(st.st_size)>limit||!noACL(fd.value))return nil;
  NSMutableData *data=[NSMutableData dataWithLength:size_t(st.st_size)];
  size_t offset=0;
  while(offset<data.length){ssize_t n=::read(fd.value,(char*)data.mutableBytes+offset,data.length-offset);
    if(n<0&&errno==EINTR)continue;if(n<=0)return nil;offset+=size_t(n);}
  char extra;if(::read(fd.value,&extra,1)!=0)return nil;
  return data;
}
inline NSDictionary *readPlist(const char *path,size_t limit,uid_t owner) {
  NSData *data=readFile(path,limit,owner);if(!data)return nil;
  id value=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
  return [value isKindOfClass:NSDictionary.class]?value:nil;
}
inline bool privateWrite(NSString *path,NSData *data,size_t limit) {
  if(!data||data.length>limit)return false;
  NSString *folder=path.stringByDeletingLastPathComponent;
  if(![[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions:@0700} error:nil])return false;
  FD dir(open(folder.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW));
  struct stat st{};
  if(dir.value<0||fstat(dir.value,&st)||st.st_uid!=getuid()||(st.st_mode&0022)||!noACL(dir.value))return false;
  if(fchmod(dir.value,0700))return false;
  const char *name=path.lastPathComponent.fileSystemRepresentation;
  if(fstatat(dir.value,name,&st,AT_SYMLINK_NOFOLLOW)==0&&
     (!S_ISREG(st.st_mode)||st.st_uid!=getuid()||st.st_nlink!=1))return false;
  NSString *temporary=[@".write-" stringByAppendingString:NSUUID.UUID.UUIDString];
  const char *temp=temporary.fileSystemRepresentation;
  FD fd(openat(dir.value,temp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
  if(fd.value<0)return false;
  size_t offset=0;bool ok=true;
  while(offset<data.length){ssize_t n=::write(fd.value,(const char*)data.bytes+offset,data.length-offset);
    if(n<0&&errno==EINTR)continue;if(n<=0){ok=false;break;}offset+=size_t(n);}
  if(ok)ok=fsync(fd.value)==0;
  if(ok)ok=renameat(dir.value,temp,dir.value,name)==0;
  if(!ok)unlinkat(dir.value,temp,0);else fsync(dir.value);
  return ok;
}
}
