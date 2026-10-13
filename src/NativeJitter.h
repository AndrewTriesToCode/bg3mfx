#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>
BOOL BG3MFXInstallNativeJitter(intptr_t slide, void (*report)(NSDictionary *), NSError **error);
