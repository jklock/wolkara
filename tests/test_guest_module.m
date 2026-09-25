#import "GuestModule.h"
#include <assert.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc==2);
        NSFileManager *fm=NSFileManager.defaultManager;
        NSString *tmp=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *root=[tmp stringByAppendingPathComponent:@"modules"];
        NSError *error=nil;
        assert(!guest_module_selected(root,&error) && error);
        NSString *source=@(argv[1]);
        NSData *original=[NSData dataWithContentsOfFile:source]; assert(original.length);
        assert(guest_module_import(source,root,&error));
        NSString *path=guest_module_selected(root,&error); assert(path);
        assert([[NSData dataWithContentsOfFile:path] isEqual:original]);
        struct stat st; assert(!stat(path.fileSystemRepresentation,&st) && !(st.st_mode & 0111));
        assert(guest_module_import(source,root,&error)); // repeat import
        NSString *bad=[tmp stringByAppendingPathComponent:@"bad"];
        assert([@"not a Mach-O" writeToFile:bad atomically:YES encoding:NSUTF8StringEncoding error:&error]);
        assert(!guest_module_import(bad,root,&error));
        assert([guest_module_selected(root,&error) isEqual:path]); // failed import preserves selection
        assert([@"corrupted" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]);
        assert(!guest_module_selected(root,&error));
        assert(guest_module_import(source,root,&error)); // repair damaged cached module
        assert([[NSData dataWithContentsOfFile:guest_module_selected(root,&error)] isEqual:original]);
        assert([fm removeItemAtPath:path error:&error]);
        assert(!symlink(source.fileSystemRepresentation,path.fileSystemRepresentation));
        assert(!guest_module_selected(root,&error)); // do not follow executable symlinks
        NSString *current=[root stringByAppendingPathComponent:@"current.json"];
        assert([@"{\"sha256\":\"../../outside\"}" writeToFile:current atomically:YES encoding:NSUTF8StringEncoding error:&error]);
        assert(!guest_module_selected(root,&error));
        assert([@"[]" writeToFile:current atomically:YES encoding:NSUTF8StringEncoding error:&error]);
        assert(!guest_module_selected(root,&error));
        assert([[NSData dataWithContentsOfFile:source] isEqual:original]);
        assert([fm removeItemAtPath:tmp error:&error]);
        puts("PASS: separate module import, integrity, atomic selection, repair, invalid images and symlinks");
    }
}
