#import <Foundation/Foundation.h>

// Identifies the installed bundle across a check, download and eventual swap.
NSString *BFApplicationIdentity(NSURL *bundle);
void BFReplaceApplication(NSURL *archive, NSURL *current, NSString *version,
                          NSString *expectedIdentity, BOOL (^verifyArchive)(NSURL *));
