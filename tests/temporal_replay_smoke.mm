#import "../src/MetalFXPipeline.h"
#include <cmath>
#include <algorithm>
#include <cstdlib>
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 1;
        NSString *prefix=@(argv[1]);
        NSDictionary *m=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[prefix stringByAppendingString:@".json"]] options:0 error:nil];
        if (!m) return 2;
        NSUInteger w=[m[@"width"] unsignedIntegerValue], h=[m[@"height"] unsignedIntegerValue];
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr,"No Metal device available for captured-input replay.\n"); return 10; }
        id<MTLCommandQueue> queue=[device newCommandQueue];
        NSArray *names=@[@"color",@"depth",@"motion"];
        MTLPixelFormat formats[]={MTLPixelFormatRGBA16Float,MTLPixelFormatR32Float,MTLPixelFormatRG16Float};
        NSMutableArray *textures=[NSMutableArray array];
        for (NSUInteger i=0;i<3;++i) {
            NSData *data=[NSData dataWithContentsOfFile:[prefix stringByAppendingFormat:@"-%@.bin",names[i]]];
            NSUInteger row=[m[@"rows"][names[i]] unsignedIntegerValue];
            if (!data || data.length != row*h) return 3;
            NSUInteger nonfinite=0; float low=INFINITY,high=-INFINITY;
            for (NSUInteger y=0;y<h;++y) for (NSUInteger x=0;x<w;++x) {
                NSUInteger channels=i==0 ? 4 : i==1 ? 1 : 2;
                for (NSUInteger c=0;c<channels;++c) {
                    const uint8_t *p=(const uint8_t *)data.bytes+y*row;
                    float v=i==1 ? ((const float *)p)[x] : ((const __fp16 *)p)[x*channels+c];
                    if (!std::isfinite(v)) ++nonfinite; else { low=fmin(low,v); high=fmax(high,v); }
                }
            }
            fprintf(stderr,"%s input: %lu nonfinite, range %g to %g\n",[names[i] UTF8String],nonfinite,low,high);
            if (nonfinite) return 4;
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[i] width:w height:h mipmapped:NO];
            d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead;
            id<MTLTexture> t=[device newTextureWithDescriptor:d];
            if (!t) { fprintf(stderr,"Could not allocate captured-input texture.\n"); return 10; }
            [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:data.bytes bytesPerRow:row];
            [textures addObject:t];
        }
        NSError *error=nil;
        BG3MFXPipeline *pipeline=[[BG3MFXPipeline alloc] initWithDevice:device inputWidth:w inputHeight:h
            outputWidth:[m[@"outputWidth"] unsignedIntegerValue] outputHeight:[m[@"outputHeight"] unsignedIntegerValue]
            colorFormat:formats[0] depthFormat:formats[1] motionFormat:formats[2] outputFormat:MTLPixelFormatRGBA16Float error:&error];
        if (!pipeline) { fprintf(stderr,"%s\n",error.description.UTF8String); return 5; }
        BG3MFXFrameParameters p={};
        p.jitterX=[m[@"jitterX"] floatValue]; p.jitterY=[m[@"jitterY"] floatValue];
        p.motionScaleX=[m[@"motionScaleX"] floatValue]; p.motionScaleY=[m[@"motionScaleY"] floatValue];
        p.depthReversed=[m[@"depthReversed"] boolValue]; p.reset=[m[@"reset"] boolValue];
        int frameCount=getenv("BG3MFX_REPLAY_FRAMES") ? std::clamp(atoi(getenv("BG3MFX_REPLAY_FRAMES")),1,16) : 3;
        for (int i=0;i<frameCount;++i) {
            if (getenv("BG3MFX_REPLAY_SEQUENCE")) {
                NSString *next=[[prefix stringByDeletingLastPathComponent] stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%d",MIN(frameCount-1,i+(getenv("BG3MFX_REPLAY_START") ? atoi(getenv("BG3MFX_REPLAY_START")) : 0))]];
                NSDictionary *meta=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[next stringByAppendingString:@".json"]] options:0 error:nil];
                if (!meta || [meta[@"width"] unsignedIntegerValue]!=w || [meta[@"height"] unsignedIntegerValue]!=h) return 8;
                if (!getenv("BG3MFX_REPLAY_FIXED_JITTER")) {
                    p.jitterX=[meta[@"jitterX"] floatValue]; p.jitterY=[meta[@"jitterY"] floatValue];
                }
                p.reset=[meta[@"reset"] boolValue];
                for (NSUInteger t=0;t<3;++t) {
                    const char *only=getenv("BG3MFX_REPLAY_ONLY");
                    if (only && strcmp(only,[names[t] UTF8String])) continue;
                    NSData *data=[NSData dataWithContentsOfFile:[next stringByAppendingFormat:@"-%@.bin",names[t]]];
                    NSUInteger row=[meta[@"rows"][names[t]] unsignedIntegerValue];
                    if (!data || data.length!=row*h) return 8;
                    [textures[t] replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:data.bytes bytesPerRow:row];
                }
            }
            // Diagnostic comparison of historical inputs recorded before a
            // convention correction; never a live runtime tuning option.
            BG3MFXFrameParameters encoded=p;
            if (getenv("BG3MFX_REPLAY_JITTER_SIGN")) {
                float sign=atof(getenv("BG3MFX_REPLAY_JITTER_SIGN"));
                encoded.jitterX*=sign; encoded.jitterY*=sign;
            }
            id<MTLCommandBuffer> b=[queue commandBuffer];
            BG3MFXFrame *f=[pipeline encodeColor:textures[0] depth:textures[1] motion:textures[2] parameters:encoded commandBuffer:b error:&error];
            if (!f) return 6;
            NSUInteger outputRow=(f.rendered.width*8+255)&~255UL;
            id<MTLBuffer> output=[device newBufferWithLength:outputRow*f.rendered.height options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit=[b blitCommandEncoder];
            [blit copyFromTexture:f.rendered sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(f.rendered.width,f.rendered.height,1) toBuffer:output destinationOffset:0
                destinationBytesPerRow:outputRow destinationBytesPerImage:output.length];
            [blit endEncoding];
            [b commit]; [b waitUntilCompleted];
            if (b.status!=MTLCommandBufferStatusCompleted) { fprintf(stderr,"%s\n",b.error.description.UTF8String); return 7; }
            for (NSUInteger y=0;y<f.rendered.height;++y) {
                const __fp16 *pixels=(const __fp16 *)((const uint8_t *)output.contents+y*outputRow);
                for (NSUInteger x=0;x<f.rendered.width*4;++x) if (!std::isfinite((float)pixels[x])) {
                    fprintf(stderr,"Nonfinite Temporal output in frame %d at row %lu, component %lu\n",i,y,x); return 9;
                }
            }
            if (const char *directory=getenv("BG3MFX_REPLAY_OUTPUT")) {
                NSString *root=@(directory);
                [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *name=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%d",i]];
                if (![[NSData dataWithBytes:output.contents length:output.length]
                    writeToFile:[name stringByAppendingString:@"-output.bin"] atomically:YES]) return 11;
                NSDictionary *meta=@{@"width":@(f.rendered.width),@"height":@(f.rendered.height),@"row":@(outputRow),
                    @"jitterX":@(encoded.jitterX),@"jitterY":@(encoded.jitterY),@"requestedReset":@(encoded.reset)};
                if (![[NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil]
                    writeToFile:[name stringByAppendingString:@".json"] atomically:YES]) return 11;
            }
            p.reset=NO;
        }
        printf("Captured Temporal inputs replayed through MetalFX for %d frames.\n",frameCount);
    }
}
