#import <Foundation/Foundation.h>

// Invoked only after verifying the downloaded release digest.
void BFReplaceApplication(NSURL *archive,NSURL *current,NSString *expectedVersion);

