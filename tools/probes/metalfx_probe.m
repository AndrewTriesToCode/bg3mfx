#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "No Metal device available\n"); return 1; }
        NSDictionary *result = @{
            @"device": device.name,
            @"spatialUpscaling": @([MTLFXSpatialScalerDescriptor supportsDevice:device]),
            @"temporalUpscaling": @([MTLFXTemporalScalerDescriptor supportsDevice:device]),
            // API compatibility, not a neural-model selection switch.
            @"metal4TemporalUpscaling": @([MTLFXTemporalScalerDescriptor supportsMetal4FX:device]),
            @"osVersion": NSProcessInfo.processInfo.operatingSystemVersionString
        };
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
        if (!json) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}
