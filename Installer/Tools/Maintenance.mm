// One-shot, allowlisted installer filesystem operations. Not a privileged service.
#include "SecureFile.hpp"
#import <Security/Security.h>
#include <dirent.h>
#include <copyfile.h>
#include <sys/wait.h>
#include <stdexcept>
#include <string>
#include <vector>
#include <iostream>
using namespace meq;
namespace {
#ifdef MEQ_INSTALLER_FIXTURE
uid_t expectedOwner(){return getuid();}
std::string fixtureRoot;
#else
uid_t expectedOwner(){return 0;}
#endif
std::string path(const char *value){
#ifdef MEQ_INSTALLER_FIXTURE
  return fixtureRoot+value;
#else
  return value;
#endif
}
[[noreturn]] void fail(const char *why){throw std::runtime_error(why);}
#define require(condition, why) do { if(!(condition))fail(why); } while(false)
constexpr const char *supportPath="/Library/Application Support/myEq";
struct Item{const char *path,*name,*role,*identifier;};
const Item items[]={
  {"/Applications/myEq.app","myEq.app","app","com.tc.myEq"},
  {"/Library/Audio/Plug-Ins/HAL/myEq.driver","myEq.driver","driver","com.tc.myEq.driver"},
  {"/Library/Application Support/myEq/myEqBridge","myEqBridge","bridge","com.tc.myEq.bridge"},
  {"/Library/Application Support/myEq/trust.plist","trust.plist",nullptr,nullptr},
  {"/Library/LaunchDaemons/com.tc.myEq.bridge.plist","com.tc.myEq.bridge.plist",nullptr,nullptr}
};
void safeStat(int fd,bool directory){struct stat st{};require(fstat(fd,&st)==0,"Cannot inspect installed object.");
  require((directory?S_ISDIR(st.st_mode):S_ISREG(st.st_mode))&&st.st_uid==expectedOwner()&&!(st.st_mode&0022)&&
    (directory||(st.st_nlink==1&&!(st.st_mode&07000)))&&noACL(fd),"Unsafe object type, owner, permissions, ACL or hard link.");}
// Walk from the filesystem root using directory descriptors; never follow a link.
int directory(const std::string &value,bool create=false){
  require(!value.empty()&&value[0]=='/',"Absolute directory required.");
  int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);require(fd>=0,"Cannot open root.");
  size_t begin=1;std::string walked;
  while(begin<value.size()){
    auto end=value.find('/',begin);auto part=value.substr(begin,end==std::string::npos?end:end-begin);begin=end==std::string::npos?value.size():end+1;
    if(part.empty())continue;walked+="/"+part;require(part!="."&&part!="..","Unexpected path component.");
    if(create&&mkdirat(fd,part.c_str(),0755)&&errno!=EEXIST){close(fd);throw std::runtime_error("Cannot create installation directory.");}
    int next=openat(fd,part.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(fd);require(next>=0,"Unsafe installation directory.");fd=next;
    struct stat st{};require(fstat(fd,&st)==0,"Cannot inspect directory.");
#ifdef MEQ_INSTALLER_FIXTURE
    // System ancestors of the private test root are not fixture-owned.
    if(walked.size()<fixtureRoot.size())continue;
#endif
    // /Applications is normally root:admin 0775. Anchor it, but do not alter it.
    bool applications=walked==path("/Applications");
    if(applications)require(st.st_uid==expectedOwner()&&!(st.st_mode&0002)&&noACL(fd),"Unsafe Applications directory.");
    else safeStat(fd,true);
  }
  return fd;
}
std::string parent(const std::string &p){return p.substr(0,p.find_last_of('/'));}
std::string basename(const std::string &p){return p.substr(p.find_last_of('/')+1);}
DIR *entriesFor(int fd){
  int copied=dup(fd);require(copied>=0,"Cannot duplicate directory descriptor.");
  auto entries=fdopendir(copied);if(!entries){close(copied);fail("Cannot enumerate directory.");}return entries;
}
void inspectTree(int dir,const char *name){
  FD fd(openat(dir,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC));require(fd.value>=0,"Cannot open installed object without following links.");
  struct stat st{};require(fstat(fd.value,&st)==0,"Cannot inspect installed object.");safeStat(fd.value,S_ISDIR(st.st_mode));
  if(S_ISDIR(st.st_mode)){
    DIR *entries=entriesFor(fd.value);require(entries,"Cannot read directory.");
    try{while(auto e=readdir(entries)){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;inspectTree(fd.value,e->d_name);}}
    catch(...){closedir(entries);throw;}closedir(entries);
  }
}
void copyTree(int source,const char *name,int dest,const char *newName){
  FD input(openat(source,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC));require(input.value>=0,"Cannot snapshot installed object.");
  struct stat st{};require(fstat(input.value,&st)==0,"Cannot inspect snapshot source.");safeStat(input.value,S_ISDIR(st.st_mode));
  if(S_ISDIR(st.st_mode)){
    require(mkdirat(dest,newName,0755)==0,"Cannot create snapshot directory.");FD output(openat(dest,newName,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));require(output.value>=0,"Cannot open snapshot directory.");
    DIR *entries=entriesFor(input.value);require(entries,"Cannot enumerate snapshot.");
    try{while(auto e=readdir(entries)){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;copyTree(input.value,e->d_name,output.value,e->d_name);}}
    catch(...){closedir(entries);throw;}closedir(entries);
  }else{
    FD output(openat(dest,newName,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,st.st_mode&0111?0755:0644));require(output.value>=0,"Cannot create snapshot file.");
    require(fcopyfile(input.value,output.value,nullptr,COPYFILE_DATA)==0&&fsync(output.value)==0,"Cannot copy snapshot file.");
  }
}
void removeTree(int dir,const char *name){
  struct stat st{};if(fstatat(dir,name,&st,AT_SYMLINK_NOFOLLOW)){if(errno==ENOENT)return;fail("Cannot inspect removal target.");}
  // All recursive removals are confined to a root-owned private staging directory.
  if(S_ISDIR(st.st_mode)){
    FD child(openat(dir,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));require(child.value>=0,"Cannot open removal directory.");safeStat(child.value,true);
    DIR *entries=entriesFor(child.value);require(entries,"Cannot enumerate removal directory.");
    try{while(auto e=readdir(entries)){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;removeTree(child.value,e->d_name);}}
    catch(...){closedir(entries);throw;}closedir(entries);require(unlinkat(dir,name,AT_REMOVEDIR)==0,"Cannot remove directory.");
  }else require(unlinkat(dir,name,0)==0,"Cannot remove file.");
}
NSString *hashFor(const std::string &p,const char *identifier){
  SecStaticCodeRef code=nullptr;CFDictionaryRef info=nullptr;
  NSURL *url=[NSURL fileURLWithPath:@(p.c_str())];
  require(SecStaticCodeCreateWithPath((__bridge CFURLRef)url,kSecCSDefaultFlags,&code)==errSecSuccess,"Cannot inspect code signature.");
  OSStatus valid=SecStaticCodeCheckValidity(code,kSecCSStrictValidate|kSecCSCheckAllArchitectures|kSecCSCheckNestedCode,nullptr);
  OSStatus copied=SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info);CFRelease(code);
  require(valid==errSecSuccess&&copied==errSecSuccess,"Invalid executable signature.");
  NSDictionary *details=CFBridgingRelease(info);NSData *hash=details[(__bridge NSString*)kSecCodeInfoUnique];
  require([details[(__bridge NSString*)kSecCodeInfoIdentifier] isEqualToString:@(identifier)]&&hash.length==20,"Unexpected signing identity.");
  NSMutableString *hex=[NSMutableString string];for(NSUInteger i=0;i<hash.length;i++)[hex appendFormat:@"%02x",((const unsigned char*)hash.bytes)[i]];
  return hex;
}
void matches(const std::string &p,id expected,const char *identifier){require([expected isKindOfClass:NSString.class]&&[hashFor(p,identifier) isEqual:expected],"Executable does not match the trusted installation manifest.");}
std::string location(const Item &item,const std::string &backup){return backup.empty()?path(item.path):backup+"/"+item.name;}
NSMutableDictionary *validate(const std::string &backup="",bool legacy=false){
  for(auto item:items){auto p=location(item,backup);FD dir(directory(parent(p)));inspectTree(dir.value,basename(p).c_str());}
  auto manifest=location(items[3],backup);NSDictionary *trust=readPlist(manifest.c_str(),64*1024,expectedOwner());require(trust,"Invalid trust manifest.");
  NSMutableDictionary *result=[trust mutableCopy];
  for(auto item:items)if(item.role){
    auto p=location(item,backup);
    if(legacy&&!result[@(item.role)]&&std::string(item.role)=="driver")result[@(item.role)]=hashFor(p,item.identifier);
    else matches(p,result[@(item.role)],item.identifier);
  }
  std::string app=location(items[0],backup);
  matches(app+"/Contents/Helpers/myEqRecovery",result[@"recovery"],"com.tc.myEq.recovery");
  auto driverTrust=readPlist((location(items[1],backup)+"/Contents/Resources/BridgeTrust.plist").c_str(),64*1024,expectedOwner());
  require([driverTrust[@"bridge"] isEqual:result[@"bridge"]],"Driver and bridge trust do not match.");
  auto daemon=readPlist(location(items[4],backup).c_str(),16*1024,expectedOwner());
  NSDictionary *expected=@{@"Label":@"com.tc.myEq.bridge",@"ProgramArguments":@[@"/Library/Application Support/myEq/myEqBridge"],@"UserName":@"nobody",@"MachServices":@{@"com.tc.myEq.bridge":@YES},@"ProcessType":@"Interactive"};
  // Permit exactly the previous and current complete schemas for upgrade/rollback.
  NSMutableDictionary *legacyExpected=[expected mutableCopy];legacyExpected[@"ProcessType"]=@"Background";
  require([daemon isEqualToDictionary:expected]||[daemon isEqualToDictionary:legacyExpected],"Unexpected bridge launch configuration.");
  return result;
}
void writeManifest(int dir,NSDictionary *value){
  NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];require(data&&data.length<=64*1024,"Invalid manifest size.");
  std::string name=".trust-"+std::string(NSUUID.UUID.UUIDString.UTF8String);
  FD fd(openat(dir,name.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0644));require(fd.value>=0,"Cannot stage manifest.");
  size_t offset=0;while(offset<data.length){ssize_t n=::write(fd.value,(const char*)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR)continue;require(n>0,"Cannot write manifest.");offset+=size_t(n);}
  require(fsync(fd.value)==0&&renameat(dir,name.c_str(),dir,"trust.plist")==0,"Cannot publish manifest.");fsync(dir);
}
std::string newStage(){
  FD support(directory(path(supportPath),true));std::string name=".maintenance-"+std::string(NSUUID.UUID.UUIDString.UTF8String)+".noindex";
  require(mkdirat(support.value,name.c_str(),0700)==0,"Cannot create maintenance stage.");return path(supportPath)+"/"+name;
}
int run(NSString *program,NSArray<NSString*> *arguments){
#ifdef MEQ_INSTALLER_FIXTURE
  (void)program;(void)arguments;return 0;
#else
  NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:program];task.arguments=arguments;
  require([task launchAndReturnError:nil],"Cannot launch maintenance command.");[task waitUntilExit];return task.terminationStatus;
#endif
}
void restoreAndStop(const std::string &snapshot){
  struct stat console{};
  if(stat("/dev/console",&console)==0&&console.st_uid>=500){
    std::string helper=snapshot+"/myEq.app/Contents/Helpers/myEqRecovery";
    // Snapshot is root-writable only; permit the console user to traverse it.
    FD stage(directory(snapshot));require(fchmod(stage.value,0755)==0,"Cannot expose verified recovery executable.");
    require(run(@"/bin/launchctl",@[@"asuser",@(std::to_string(console.st_uid).c_str()),@"/usr/bin/sudo",@"-u",@(("#"+std::to_string(console.st_uid)).c_str()),@(helper.c_str()),@"--restore"])==0,"Recovery could not restore ordinary playback.");
    run(@"/bin/launchctl",@[@"bootout",@(("gui/"+std::to_string(console.st_uid)+"/com.tc.myEq.recovery").c_str())]);
  }
  run(@"/bin/launchctl",@[@"bootout",@"system/com.tc.myEq.bridge"]);
}
std::string snapshotCurrent(){
  auto trust=validate("",true);auto stage=newStage();FD dest(directory(stage));
  for(auto item:items){auto p=path(item.path);FD source(directory(parent(p)));copyTree(source.value,basename(p).c_str(),dest.value,item.name);}
  writeManifest(dest.value,trust);validate(stage);return stage;
}
void replaceFrom(int stage,const Item &item){
  auto p=path(item.path);FD dest(directory(parent(p)));auto name=basename(p);
  struct stat before{};bool exists=fstatat(dest.value,name.c_str(),&before,AT_SYMLINK_NOFOLLOW)==0;
  if(exists)inspectTree(dest.value,name.c_str());
  require(renameatx_np(stage,item.name,dest.value,name.c_str(),exists?RENAME_SWAP:RENAME_EXCL)==0,"Cannot atomically replace installed object.");
  if(exists){struct stat moved{};require(fstatat(stage,item.name,&moved,AT_SYMLINK_NOFOLLOW)==0&&moved.st_dev==before.st_dev&&moved.st_ino==before.st_ino,"Concurrent installation change; retained recovery stage.");}
}
bool audioReloadRequired(){
  auto current=validate();
  FD support(directory(path(supportPath)));inspectTree(support.value,"myEqMaintenance");
  matches(path("/Library/Application Support/myEq/myEqMaintenance"),current[@"maintenance"],"com.tc.myEq.maintenance");
  const auto backup=path(supportPath)+"/previous.noindex";
  struct stat st{};
  if(lstat(backup.c_str(),&st)!=0){require(errno==ENOENT,"Cannot inspect previous installation.");return true;}
  // Only a fully validated, protected snapshot can justify skipping a reload.
  auto previous=validate(backup,true);
  return ![current[@"driver"] isEqual:previous[@"driver"]] || ![current[@"bridge"] isEqual:previous[@"bridge"]];
}
void postflight(){
  auto trust=validate();FD support(directory(path(supportPath)));
  auto maintenance=path("/Library/Application Support/myEq/myEqMaintenance");inspectTree(support.value,"myEqMaintenance");matches(maintenance,trust[@"maintenance"],"com.tc.myEq.maintenance");
  trust[@"installationID"]=NSUUID.UUID.UUIDString;writeManifest(support.value,trust);
}
void prepare(){
  {FD support(directory(path(supportPath),true));struct stat existing{};
    if(fstatat(support.value,"myEqMaintenance",&existing,AT_SYMLINK_NOFOLLOW)==0)inspectTree(support.value,"myEqMaintenance");
    else require(errno==ENOENT,"Cannot inspect existing maintenance executable.");}
  for(auto item:items){FD parentFD(directory(parent(path(item.path)),true));struct stat st{};
    if(fstatat(parentFD.value,basename(path(item.path)).c_str(),&st,AT_SYMLINK_NOFOLLOW)==0)inspectTree(parentFD.value,basename(path(item.path)).c_str());
  }
  auto trust=path("/Library/Application Support/myEq/trust.plist");struct stat st{};
  if(lstat(trust.c_str(),&st)==0){
    auto stage=snapshotCurrent();restoreAndStop(stage);FD support(directory(path(supportPath)));
    struct stat prior{};if(fstatat(support.value,"previous.noindex",&prior,AT_SYMLINK_NOFOLLOW)==0){inspectTree(support.value,"previous.noindex");removeTree(support.value,"previous.noindex");}
    require(renameat(support.value,basename(stage).c_str(),support.value,"previous.noindex")==0,"Cannot retain previous installation.");
  }else{
    // A fresh install must not execute or overwrite an unrelated pre-existing app.
    for(auto item:items)require(lstat(path(item.path).c_str(),&st)!=0&&errno==ENOENT,"Existing components have no trusted manifest. Remove them manually first.");
  }
}
void rollback(){
  std::string backup=path(supportPath)+"/previous.noindex";auto oldTrust=validate(backup,true);
  auto current=snapshotCurrent();auto stage=newStage();FD source(directory(backup)),dest(directory(stage));
  for(auto item:items)copyTree(source.value,item.name,dest.value,item.name);
  oldTrust[@"maintenance"]=hashFor(path("/Library/Application Support/myEq/myEqMaintenance"),"com.tc.myEq.maintenance");
  writeManifest(dest.value,oldTrust);validate(stage);restoreAndStop(current);
  for(auto item:items)replaceFrom(dest.value,item);
  postflight(); // Do not start services if any component or trust relationship is invalid.
  require(run(@"/bin/launchctl",@[@"bootstrap",@"system",@"/Library/LaunchDaemons/com.tc.myEq.bridge.plist"])==0,"Cannot start restored bridge.");
}
void uninstall(){
  auto stage=snapshotCurrent();restoreAndStop(stage);FD quarantine(directory(stage));
  // Move exact targets into a private directory before deleting; never recursively
  // remove a caller-writable path or follow a substituted directory during removal.
  for(auto item:items){auto p=path(item.path);FD source(directory(parent(p)));auto name=basename(p);struct stat before{},after{};
    require(fstatat(source.value,name.c_str(),&before,AT_SYMLINK_NOFOLLOW)==0,"Missing installation component.");inspectTree(source.value,name.c_str());
    std::string removed="removed-"+name;require(renameat(source.value,name.c_str(),quarantine.value,removed.c_str())==0,"Cannot quarantine installed component.");
    require(fstatat(quarantine.value,removed.c_str(),&after,AT_SYMLINK_NOFOLLOW)==0&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino,"Concurrent removal change; retained quarantine.");removeTree(quarantine.value,removed.c_str());
  }
  FD support(directory(path(supportPath)));removeTree(support.value,"myEqMaintenance");
  // Retain recovery snapshots under this root-owned directory; user presets are untouched.
}
}
int main(int argc,const char **argv){@autoreleasepool{try{
#ifdef MEQ_INSTALLER_FIXTURE
  require(argc==3,"Fixture root and operation required.");fixtureRoot=argv[1];const char *operation=argv[2];
#else
  require(getuid()==0&&geteuid()==0&&argc==2,"Run the maintenance utility as root with one operation.");const char *operation=argv[1];
#endif
  if(!strcmp(operation,"prepare"))prepare();else if(!strcmp(operation,"verify"))postflight();
  else if(!strcmp(operation,"audio-reload-policy"))std::cout<<(audioReloadRequired()?"reload":"keep")<<"\n";
  else if(!strcmp(operation,"rollback"))rollback();else if(!strcmp(operation,"uninstall"))uninstall();
  else throw std::runtime_error("Unknown maintenance operation.");
  return 0;
}catch(const std::exception &e){std::cerr<<"myEq maintenance: "<<e.what()<<"\n";return 1;}}}
