#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>
BOOL BG3MFXInstallTemporalJitter(intptr_t slide, void (*report)(NSDictionary *), NSError **error);
