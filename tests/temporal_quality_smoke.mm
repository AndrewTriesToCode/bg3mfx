#import "../src/TemporalUpscaler.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

// Analytic geometry supplies independent ground truth. Uniform-color tests
// cannot detect failed accumulation, an inverted jitter, or bad reprojection.
static float halton(unsigned i, unsigned base) {
    float result=0, weight=1;
    while (i) { weight/=base; result+=(i%base)*weight; i/=base; }
    return result;
}
static float scene(float x, float y) {
    float line=std::abs(x-0.63f*y-57.3f);
    float ring=std::abs(std::hypot(x-185.7f,y-125.1f)-43.7f);
    return (line<0.85f || ring<0.85f || (x>215 && y>60 && y<190)) ? 0.9f : 0.08f;
}
static float reference(float x, float y, float shift) {
    float value=0;
    for (unsigned j=0;j<8;++j) for (unsigned i=0;i<8;++i)
        value+=scene(x+(i+0.5f)/8,y+(j+0.5f)/8-shift);
    return value/64;
}
static float bilinear(const std::vector<__fp16> &color, unsigned w, unsigned h, float x, float y) {
    x=std::clamp(x,0.0f,float(w-1)); y=std::clamp(y,0.0f,float(h-1));
    unsigned x0=unsigned(x),y0=unsigned(y),x1=std::min(x0+1,w-1),y1=std::min(y0+1,h-1);
    float u=x-x0,v=y-y0;
    return (1-v)*((1-u)*color[(y0*w+x0)*4]+u*color[(y0*w+x1)*4])+
        v*((1-u)*color[(y1*w+x0)*4]+u*color[(y1*w+x1)*4]);
}
static void image(NSString *path, const std::vector<float> &pixels, unsigned w, unsigned h) {
    FILE *f=fopen(path.fileSystemRepresentation,"wb");
    if (!f) return;
    fprintf(f,"P6\n%u %u\n255\n",w,h);
    for (float p:pixels) {
        unsigned char rgb[3];
        rgb[0]=rgb[1]=rgb[2]=(unsigned char)std::lround(std::clamp(p,0.0f,1.0f)*255);
        fwrite(rgb,1,3,f);
    }
    fclose(f);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc!=2) { fprintf(stderr,"Usage: temporal-quality-smoke output-directory\n"); return 1; }
        NSString *root=@(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr,"No Metal device available.\n"); return 2; }
        id<MTLCommandQueue> queue=[device newCommandQueue];
        bool failed=false;
        for (float scale:{1.5f,2.0f}) for (bool moving:{false,true}) {
            const unsigned w=256,h=192,outW=unsigned(w*scale),outH=unsigned(h*scale);
            id<MTLTexture> inputs[3];
            const MTLPixelFormat formats[]={MTLPixelFormatRGBA16Float,MTLPixelFormatR32Float,MTLPixelFormatRG16Float};
            for (unsigned i=0;i<3;++i) {
                MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[i] width:w height:h mipmapped:NO];
                d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead;
                inputs[i]=[device newTextureWithDescriptor:d];
                if (!inputs[i]) return 2;
            }
            NSError *error=nil;
            BG3MFXPipeline *pipeline=[[BG3MFXPipeline alloc] initWithDevice:device inputWidth:w inputHeight:h outputWidth:outW outputHeight:outH
                colorFormat:formats[0] depthFormat:formats[1] motionFormat:formats[2] outputFormat:MTLPixelFormatRGBA16Float error:&error];
            if (!pipeline) { fprintf(stderr,"%s\n",error.description.UTF8String); return 3; }
            unsigned phases=unsigned(std::ceil(8*scale*scale));
            if (getenv("BG3MFX_QUALITY_PHASES")) phases=std::clamp(atoi(getenv("BG3MFX_QUALITY_PHASES")),1,128);
            // The analytic renderer samples scene(pixel + jitter). MetalFX
            // takes the opposite image displacement, as BG3's adapter must.
            const bool legacyJitter=getenv("BG3MFX_QUALITY_LEGACY_JITTER") != nullptr;
            const float motionSign=getenv("BG3MFX_QUALITY_MOTION_SIGN") ? atof(getenv("BG3MFX_QUALITY_MOTION_SIGN")) : 1;
            const unsigned count=phases*3;
            std::vector<__fp16> color(w*h*4),motion(w*h*2);
            std::vector<float> depth(w*h,0.5f),native(outW*outH),linear(outW*outH),temporal(outW*outH);
            double firstError=0,lastError=0,linearError=0;
            for (unsigned frame=0;frame<count;++frame) {
                const float jx=halton(frame%phases+1,2)-0.5f,jy=halton(frame%phases+1,3)-0.5f;
                const float speed=moving ? 0.35f : 0,shift=frame*speed;
                for (unsigned y=0;y<h;++y) for (unsigned x=0;x<w;++x) {
                    float value=scene((x+0.5f+jx)*scale,(y+0.5f+jy)*scale-shift);
                    for (unsigned c=0;c<3;++c) color[(y*w+x)*4+c]=value;
                    color[(y*w+x)*4+3]=1;
                    motion[(y*w+x)*2]=0;
                    motion[(y*w+x)*2+1]=-speed/scale;
                }
                [inputs[0] replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:color.data() bytesPerRow:w*8];
                [inputs[1] replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:depth.data() bytesPerRow:w*4];
                [inputs[2] replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:motion.data() bytesPerRow:w*4];
                BG3MFXFrameParameters p={};
                BG3MFXApplyNativeJitter(&p,jx,-jy);
                if (legacyJitter) { p.jitterX=-p.jitterX; p.jitterY=-p.jitterY; }
                p.motionScaleX=p.motionScaleY=motionSign; p.depthReversed=YES;
                id<MTLCommandBuffer> b=[queue commandBuffer];
                BG3MFXFrame *result=[pipeline encodeColor:inputs[0] depth:inputs[1] motion:inputs[2] parameters:p commandBuffer:b error:&error];
                if (!result) { fprintf(stderr,"%s\n",error.description.UTF8String); return 4; }
                unsigned row=(outW*8+255)&~255U;
                id<MTLBuffer> data=[device newBufferWithLength:row*outH options:MTLResourceStorageModeShared];
                id<MTLBlitCommandEncoder> blit=[b blitCommandEncoder];
                [blit copyFromTexture:result.rendered sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                    sourceSize:MTLSizeMake(outW,outH,1) toBuffer:data destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*outH];
                [blit endEncoding]; [b commit]; [b waitUntilCompleted];
                if (b.status!=MTLCommandBufferStatusCompleted) { fprintf(stderr,"%s\n",b.error.description.UTF8String); return 5; }
                if (frame!=0 && frame!=count-1) continue;
                double e=0,be=0; unsigned n=0;
                for (unsigned y=0;y<outH;++y) for (unsigned x=0;x<outW;++x) {
                    unsigned index=y*outW+x;
                    float actual=((const __fp16 *)((const uint8_t *)data.contents+y*row))[x*4];
                    if (!std::isfinite(actual)) return 6;
                    temporal[index]=actual; native[index]=reference(x,y,shift);
                    linear[index]=bilinear(color,w,h,(x+0.5f)/scale-jx-0.5f,(y+0.5f)/scale-jy-0.5f);
                    if (x<24 || y<24 || x>=outW-24 || y>=outH-24) continue;
                    e+=std::pow(actual-native[index],2); be+=std::pow(linear[index]-native[index],2); ++n;
                }
                if (!frame) firstError=e/n;
                else { lastError=e/n; linearError=be/n; }
            }
            NSString *name=[NSString stringWithFormat:@"%.1fx-%@",scale,moving ? @"moving" : @"static"];
            image([root stringByAppendingPathComponent:[name stringByAppendingString:@"-native.ppm"]],native,outW,outH);
            image([root stringByAppendingPathComponent:[name stringByAppendingString:@"-bilinear.ppm"]],linear,outW,outH);
            image([root stringByAppendingPathComponent:[name stringByAppendingString:@"-temporal.ppm"]],temporal,outW,outH);
            printf("%s phases=%u firstMSE=%.7f settledMSE=%.7f bilinearMSE=%.7f temporal/bilinear=%.3f\n",
                name.UTF8String,phases,firstError,lastError,linearError,lastError/linearError);
            // This tests image reconstruction, not merely execution/finite pixels.
            if (lastError>=linearError || (!moving && lastError>=firstError)) failed=true;
        }
        return failed ? 7 : 0;
    }
}
