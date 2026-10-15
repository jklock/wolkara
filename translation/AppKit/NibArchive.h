#pragma once
#import <Foundation/Foundation.h>

// Reads a NIBArchive into the build-time graph, nil if unreadable.
NSDictionary *AKReadNibArchive(NSData *data);
