// bg3mfx-icon: draws BG3MFX.app's icon and writes it as an .icns file.
//   bg3mfx-icon <out.icns> [preview.png]
//
// An original design in the spirit of the game's emblem (dark iron, gilded
// bronze, points), without its artwork: a gilded gothic gate in an iron ring,
// its light breaking into pixels that grow finer, for MetalFX upscaling.
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSColor *rgb(int hex, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xff) / 255.0 green:((hex >> 8) & 0xff) / 255.0
                                blue:(hex & 0xff) / 255.0 alpha:alpha];
}

static NSGradient *gold(void) {
    return [[NSGradient alloc] initWithColorsAndLocations:
        rgb(0xfff0b8, 1), 0.0, rgb(0xe9b85a, 1), 0.28, rgb(0x9c6420, 1), 0.55,
        rgb(0xe3ad52, 1), 0.78, rgb(0x6e4314, 1), 1.0, nil];
}

static NSGradient *iron(void) {
    return [[NSGradient alloc] initWithColorsAndLocations:
        rgb(0x9aa0a8, 1), 0.0, rgb(0x4a4e55, 1), 0.35, rgb(0x2a2c31, 1), 0.6,
        rgb(0x6c7078, 1), 0.85, rgb(0x1c1d21, 1), 1.0, nil];
}

// Fills a path with a metal gradient, then a thin dark edge so it reads at 16 px.
static void metal(NSBezierPath *path, NSGradient *gradient, CGFloat angle, CGFloat edge) {
    [gradient drawInBezierPath:path angle:angle];
    if (edge > 0) {
        [rgb(0x0a0806, 0.85) setStroke];
        path.lineWidth = edge;
        [path stroke];
    }
}

// A gothic (equilateral) arch on a base from x0 to x1 at y, with legs of height h.
static NSBezierPath *arch(CGFloat x0, CGFloat x1, CGFloat y, CGFloat h) {
    CGFloat w = x1 - x0, top = y + h;
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(x0, y)];
    [path lineToPoint:NSMakePoint(x0, top)];
    // Each side is an arc centred on the opposite springing point.
    [path appendBezierPathWithArcWithCenter:NSMakePoint(x1, top) radius:w startAngle:180 endAngle:120 clockwise:YES];
    [path appendBezierPathWithArcWithCenter:NSMakePoint(x0, top) radius:w startAngle:60 endAngle:0 clockwise:YES];
    [path lineToPoint:NSMakePoint(x1, y)];
    [path closePath];
    return path;
}

static void draw(CGFloat s) {
    NSAffineTransform *scale = [NSAffineTransform transform];
    [scale scaleBy:s / 1024.0];
    [scale concat];
    NSPoint c = NSMakePoint(512, 512);

    // macOS icon grid: an 824 pt rounded square with a soft shadow.
    NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(100, 100, 824, 824) xRadius:185 yRadius:185];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = rgb(0x000000, 0.45);
    shadow.shadowBlurRadius = 24;
    shadow.shadowOffset = NSMakeSize(0, -10);
    [shadow set];
    [rgb(0x15161a, 1) setFill];
    [plate fill];
    [NSGraphicsContext restoreGraphicsState];
    [[[NSGradient alloc] initWithColorsAndLocations:rgb(0x3b3e46, 1), 0.0, rgb(0x1d1f24, 1), 0.55,
        rgb(0x0c0d10, 1), 1.0, nil] drawInBezierPath:plate relativeCenterPosition:NSMakePoint(0, 0.25)];
    [rgb(0x8a6a3a, 0.55) setStroke];
    NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(106, 106, 812, 812) xRadius:180 yRadius:180];
    rim.lineWidth = 4;
    [rim stroke];

    // Four iron points behind the ring, longest top and bottom.
    for (int i = 0; i < 4; ++i) {
        CGFloat length = (i % 2 == 0) ? 400 : 370, half = 62;
        NSBezierPath *point = [NSBezierPath bezierPath];
        [point moveToPoint:NSMakePoint(-half, 0)];
        [point lineToPoint:NSMakePoint(0, length)];
        [point lineToPoint:NSMakePoint(half, 0)];
        [point closePath];
        NSAffineTransform *place = [NSAffineTransform transform];
        [place translateXBy:c.x yBy:c.y];
        [place rotateByDegrees:-90.0 * i];
        [point transformUsingAffineTransform:place];
        metal(point, gold(), 90.0 * i + 30, 4);
    }

    // The ring: iron outside, gold inside.
    NSBezierPath *outer = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 300, c.y - 300, 600, 600)];
    metal(outer, iron(), -60, 5);
    NSBezierPath *band = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 272, c.y - 272, 544, 544)];
    [band appendBezierPath:[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 232, c.y - 232, 464, 464)] bezierPathByReversingPath]];
    metal(band, gold(), -70, 3);

    // The well inside the ring.
    NSBezierPath *well = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 232, c.y - 232, 464, 464)];
    [[[NSGradient alloc] initWithColorsAndLocations:rgb(0x24201c, 1), 0.0, rgb(0x0b0a09, 1), 1.0, nil]
        drawInBezierPath:well relativeCenterPosition:NSZeroPoint];

    // The gate: a gilded gothic arch with light behind it.
    CGFloat gx0 = c.x - 118, gx1 = c.x + 118, gy = c.y - 196, legs = 170;
    NSBezierPath *opening = arch(gx0, gx1, gy, legs);
    [NSGraphicsContext saveGraphicsState];
    [opening addClip];
    [[[NSGradient alloc] initWithColorsAndLocations:rgb(0xfff4c8, 1), 0.0, rgb(0xffc864, 1), 0.35,
        rgb(0xd97a1c, 1), 0.75, rgb(0x5a2a08, 1), 1.0, nil]
        drawInBezierPath:opening relativeCenterPosition:NSMakePoint(0, -0.35)];
    // Pixels: the light starts as coarse blocks at the threshold and resolves
    // into finer ones above, as an upscaler turns a few samples into detail.
    CGFloat y = gy, sizes[] = {48, 32, 24, 16, 12, 8};
    for (int row = 0; row < 6; ++row) {
        CGFloat size = sizes[row];
        int columns = (int)ceil((gx1 - gx0) / size);
        for (int col = 0; col < columns; ++col) {
            // A fixed scatter: each block is lit or dimmed, fewer dimmed as rows get finer.
            unsigned hash = (unsigned)(row * 7919 + col * 104729) % 97;
            if ((int)hash > 60 - row * 9) continue;
            CGFloat shade = 0.25 + (hash % 5) * 0.12;
            [(hash % 2 ? rgb(0xfff2c0, shade) : rgb(0x7a3a0c, shade)) setFill];
            NSRectFillUsingOperation(NSMakeRect(gx0 + col * size + 1, y + 1, size - 2, size - 2), NSCompositingOperationSourceOver);
        }
        y += size;
    }
    [NSGraphicsContext restoreGraphicsState];

    // The arch's gilded frame and portcullis bars.
    NSBezierPath *frame = arch(gx0 - 26, gx1 + 26, gy, legs + 2);
    [frame appendBezierPath:[opening bezierPathByReversingPath]];
    metal(frame, gold(), -80, 3);
    for (int i = -1; i <= 1; ++i) {
        CGFloat x = c.x + i * 62;
        NSBezierPath *bar = [NSBezierPath bezierPath];
        CGFloat top = gy + legs + (i == 0 ? 190 : 120), bottom = gy + 36;
        [bar moveToPoint:NSMakePoint(x - 9, top)];
        [bar lineToPoint:NSMakePoint(x + 9, top)];
        [bar lineToPoint:NSMakePoint(x + 9, bottom + 22)];
        [bar lineToPoint:NSMakePoint(x, bottom)];
        [bar lineToPoint:NSMakePoint(x - 9, bottom + 22)];
        [bar closePath];
        [NSGraphicsContext saveGraphicsState];
        [opening addClip];
        metal(bar, iron(), 0, 3);
        [NSGraphicsContext restoreGraphicsState];
    }
    NSBezierPath *rail = [NSBezierPath bezierPathWithRect:NSMakeRect(gx0, gy + legs - 10, gx1 - gx0, 16)];
    metal(rail, iron(), 90, 3);
    // Threshold step.
    metal([NSBezierPath bezierPathWithRoundedRect:NSMakeRect(gx0 - 44, gy - 22, gx1 - gx0 + 88, 26) xRadius:6 yRadius:6],
          gold(), -90, 3);
}

static CGImageRef render(int pixels) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    draw(pixels);
    [NSGraphicsContext restoreGraphicsState];
    return CGImageRetain(rep.CGImage);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: bg3mfx-icon <out.icns> [preview.png]\n"); return 2; }
        NSURL *out = [NSURL fileURLWithPath:@(argv[1])];
        const int sizes[] = {16, 32, 64, 128, 256, 512, 1024};
        CGImageDestinationRef icns = CGImageDestinationCreateWithURL((__bridge CFURLRef)out,
            (__bridge CFStringRef)UTTypeICNS.identifier, sizeof sizes / sizeof *sizes, NULL);
        if (!icns) { fprintf(stderr, "bg3mfx-icon: can't write %s\n", argv[1]); return 1; }
        for (size_t i = 0; i < sizeof sizes / sizeof *sizes; ++i) {
            CGImageRef image = render(sizes[i]);
            CGImageDestinationAddImage(icns, image, NULL);
            CGImageRelease(image);
        }
        BOOL ok = CGImageDestinationFinalize(icns);
        CFRelease(icns);
        if (!ok) { fprintf(stderr, "bg3mfx-icon: couldn't finish %s\n", argv[1]); return 1; }
        if (argc > 2) {
            CGImageRef image = render(1024);
            NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:image] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            CGImageRelease(image);
            [png writeToFile:@(argv[2]) atomically:YES];
        }
        return 0;
    }
}
